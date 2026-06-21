# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestKarafkaMessageContext < Minitest::Test
    include JulewireCapture

    cover Julewire::Karafka::MessageContext
    cover Julewire::Karafka::MessageExecution
    cover Julewire::Karafka::MessagingAttributes

    def setup
      super
      reset_julewire!
    end

    def test_with_message_restores_message_carrier_and_context_for_current_block
      records = capture_records
      carrier = carrier_from_execution("request-1")

      message = karafka_message(headers: carrier, offsets: [42])

      Julewire::Karafka.with_message(message) do
        Julewire.emit(event: "kafka.point", source: "test", payload: { ok: true })
      end

      point = records.find { it[:event] == "kafka.point" }

      assert_equal "request-1", point.dig(:context, :request_id)
      refute point.fetch(:context).key?(:topic)
      assert_equal "events", point.dig(:neutral, :"messaging.destination.name")
      assert_equal "0", point.dig(:neutral, :"messaging.destination.partition.id")
      assert_equal "42", point.dig(:neutral, :"messaging.kafka.offset")
      assert_equal "events", point.dig(:attributes, :karafka, :topic)
      assert_equal 0, point.dig(:attributes, :karafka, :partition)
      assert_equal 42, point.dig(:attributes, :karafka, :offset)
      refute(records.any? { it[:event] == "kafka.consume.completed" })
    end

    def test_karafka_uses_shared_julewire_propagation_contract
      assert_julewire_propagation_contract(key: Julewire::Karafka.config.carrier_key)
    end

    def test_karafka_uses_shared_julewire_integration_spi_contract
      assert_julewire_integration_spi_contract
    end

    def test_with_message_can_filter_inbound_carrier_headers
      assert_carrier_filter_context(
        ->(headers, message:) { message[:topic] == "trusted" ? headers : {} },
        request_id: nil
      )
    end

    def test_with_message_filter_can_accept_inbound_carrier_headers
      assert_carrier_filter_context(
        ->(headers, message:) { message[:topic] == "events" ? headers : {} },
        request_id: "spoofed"
      )
    end

    def test_with_message_ignores_oversized_inbound_carrier
      records = capture_records
      carrier = carrier_from_context("request-1")
      configuration = Julewire::Karafka::Configuration.new
      configuration.carrier_max_bytes = carrier.fetch(configuration.carrier_key).bytesize - 1

      Julewire::Karafka.with_message(karafka_message(headers: carrier, offsets: [42]),
                                     configuration: configuration) do
        Julewire.emit(event: "kafka.point", source: "test")
      end

      point = records.find { it[:event] == "kafka.point" }

      refute point.fetch(:context).key?(:request_id)
      assert_equal "events", point.dig(:attributes, :karafka, :topic)
      failure = Julewire.health.dig(:process_integrations, :karafka, :last_failure)

      assert_equal :carrier_restore, failure.fetch(:action)
      assert_equal :message_context, failure.fetch(:component)
      assert_equal :oversized, failure.fetch(:status)
    end

    def test_with_message_ignores_non_hash_filtered_carrier
      point, = emit_with_carrier_filter(->(*) { "not-a-carrier" })

      refute point.fetch(:context).key?(:request_id)
      assert_equal "events", point.dig(:attributes, :karafka, :topic)
    end

    def test_with_message_ignores_non_hash_message_headers
      records = capture_records
      message = Julewire::KarafkaTestSupport::MutableMessage.new("events", 0, 42, "not-a-carrier")

      Julewire::Karafka.with_message(message) do
        Julewire.emit(event: "kafka.point", source: "test")
      end

      point = records.find { it[:event] == "kafka.point" }

      refute point.fetch(:context).key?(:request_id)
      assert_equal "not-a-carrier", point.dig(:attributes, :karafka, :headers)
    end

    def test_with_message_contains_carrier_filter_failures
      point, health = emit_with_carrier_filter(->(*) { raise "filter failed" })

      refute point.fetch(:context).key?(:request_id)
      assert_equal :carrier_filter, health.dig(:last_failure, :action)
      assert_equal :message_context, health.dig(:last_failure, :component)
    end

    def test_with_message_context_is_captured_by_downstream_carrier_injection
      inbound_carrier = carrier_from_context("request-1")

      inbound = karafka_message(headers: inbound_carrier, offsets: [42])
      outbound = { headers: {} }

      Julewire::Karafka.with_message(inbound) do
        Julewire::Karafka.inject!(outbound)
      end

      envelope = Julewire::Core::Propagation::Carrier.extract(outbound.fetch(:headers))

      assert_equal "request-1", envelope.dig(:context, :request_id)
      refute envelope.fetch(:context).key?(:topic)
      refute envelope.fetch(:context).key?(:offset)
    end

    def test_with_message_execution_is_explicit_unit_of_work_wrapper
      records = capture_records
      inbound_carrier = carrier_from_execution("request-1")

      inbound = karafka_message(headers: inbound_carrier, offsets: [42])
      outbound = { headers: {} }

      Julewire::Karafka.with_message_execution(inbound) do
        Julewire::Karafka.inject!(outbound)
        Julewire.emit(event: "kafka.message.processed", source: "test")
      end

      point = records.find { it[:event] == "kafka.message.processed" }
      summary = records.find { it[:event] == "message.completed" }
      envelope = Julewire::Core::Propagation::Carrier.extract(outbound.fetch(:headers))

      assert_message_execution_summary(summary)
      assert_equal "events:0:42", point.dig(:execution, :id)
      assert_equal "request-1", envelope.dig(:context, :request_id)
      assert_equal "events:0:42", envelope.dig(:execution, :id)
      refute envelope.fetch(:context).key?(:topic)
    end

    def test_message_context_requires_block_and_can_skip_propagation
      configuration = Julewire::Karafka::Configuration.new
      configuration.propagation = false
      message = karafka_message(offsets: [42])

      assert_raises(ArgumentError) { Julewire::Karafka.with_message(message, configuration: configuration) }
      assert_raises(ArgumentError) { Julewire::Karafka.with_message_execution(message, configuration: configuration) }

      records = capture_records
      Julewire::Karafka.with_message(karafka_message(headers: carrier_from_context("ignored"), offsets: [42]),
                                     configuration: configuration) do
        Julewire.emit(event: "kafka.point", source: "test")

        assert_equal "events", Julewire.attributes[:karafka].fetch(:topic)
      end

      point = records.find { it[:event] == "kafka.point" }

      refute point.fetch(:context).key?(:request_id)
    end

    private

    def carrier_from_context(request_id)
      Julewire.context.with(request_id: request_id) do
        Julewire::Core::Propagation::Carrier.inject({})
      end
    end

    def carrier_from_execution(request_id)
      Julewire.with_execution(type: :request, id: request_id) do
        Julewire.context.add(request_id: request_id)
        Julewire::Core::Propagation::Carrier.inject({})
      end
    end

    def emit_with_carrier_filter(filter)
      records = capture_records
      configuration = Julewire::Karafka::Configuration.new
      configuration.carrier_filter = filter

      Julewire::Karafka.with_message(karafka_message(headers: carrier_from_context("spoofed")),
                                     configuration: configuration) do
        Julewire.emit(event: "kafka.point", source: "test")
      end

      [records.find { it[:event] == "kafka.point" }, Julewire.health.dig(:process_integrations, :karafka)]
    end

    def assert_carrier_filter_context(filter, request_id:)
      point, = emit_with_carrier_filter(filter)

      if request_id
        assert_equal request_id, point.dig(:context, :request_id)
      else
        refute point.fetch(:context).key?(:request_id)
      end

      assert_equal "events", point.dig(:attributes, :karafka, :topic)
    end

    def assert_message_execution_summary(summary)
      assert_equal "karafka_message", summary.dig(:execution, :type)
      assert_equal "events:0:42", summary.dig(:execution, :id)
      assert_equal "request-1", summary.dig(:context, :request_id)
      refute summary.fetch(:context).key?(:topic)
      assert_equal "events", summary.dig(:neutral, :"messaging.destination.name")
      assert_equal 42, summary.dig(:attributes, :karafka, :offset)
    end
  end
end
