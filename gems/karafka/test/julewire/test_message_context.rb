# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestKarafkaMessageContext < Minitest::Test
    cover Julewire::Karafka::MessageContext
    cover Julewire::Karafka::MessageExecution
    cover "Julewire::Karafka.with_message"
    cover "Julewire::Karafka.with_message_execution"
    include JulewireCapture

    class HeaderHash < Hash
    end

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
      assert_false point.fetch(:context).key?(:topic)
      assert_equal "events", point.dig(:neutral, :"messaging.destination.name")
      assert_equal "0", point.dig(:neutral, :"messaging.destination.partition.id")
      assert_equal "42", point.dig(:neutral, :"messaging.kafka.offset")
      assert_equal "events", point.dig(:attributes, :karafka, :topic)
      assert_equal 0, point.dig(:attributes, :karafka, :partition)
      assert_equal 42, point.dig(:attributes, :karafka, :offset)
      assert_false(records.any? { it[:event] == "kafka.consume.completed" })
    end

    def test_with_message_can_filter_inbound_carrier_headers
      assert_carrier_filter_context(
        ->(headers, message:) { message[:topic] == "trusted" ? headers : {} },
        request_id: nil
      )
    end

    def test_with_message_accepts_hash_subclass_carriers_and_filters
      carrier = HeaderHash[carrier_from_context("request-1")]
      configuration = Julewire::Karafka::Configuration.new
      configuration.carrier_filter = lambda { |headers, message:|
        assert_equal "events", message.fetch(:topic)
        HeaderHash[headers]
      }

      assert_message_restores_request_context(carrier: carrier, configuration: configuration)
    end

    def test_with_message_uses_configured_carrier_key
      configuration = Julewire::Karafka::Configuration.new
      configuration.carrier_key = "x-julewire"
      carrier = {}

      Julewire.context.with(request_id: "request-1") do
        Julewire::Core::Propagation::Carrier.inject(carrier, key: configuration.carrier_key)
      end

      assert_message_restores_request_context(carrier: carrier, configuration: configuration)
    end

    def test_with_message_filter_can_accept_inbound_carrier_headers
      assert_carrier_filter_context(
        ->(headers, message:) { message[:topic] == "events" ? headers : {} },
        request_id: "spoofed"
      )
    end

    def test_with_message_ignores_oversized_inbound_carrier
      carrier = carrier_from_context("request-1")
      configuration = Julewire::Karafka::Configuration.new
      configuration.carrier_max_bytes = carrier.fetch(configuration.carrier_key).bytesize - 1

      point = message_point_for_carrier(carrier: carrier, configuration: configuration)

      assert_false point.fetch(:context).key?(:request_id)
      assert_equal "events", point.dig(:attributes, :karafka, :topic)
      failure = Julewire.health.dig(:process_integrations, :karafka, :last_failure)

      assert_equal :carrier_restore, failure.fetch(:action)
      assert_equal :message_context, failure.fetch(:component)
      assert_equal :oversized, failure.fetch(:status)
      assert_equal "carrier payload exceeds max_bytes", failure.fetch(:reason)
      assert_equal "Julewire::Core::Propagation::Carrier::ExtractionError", failure.fetch(:class)
    end

    def test_with_message_records_malformed_carrier_restore_failure
      records = capture_records

      Julewire::Karafka.with_message(karafka_message(headers: { "julewire" => "not-json" }, offsets: [42])) do
        Julewire.emit(event: "kafka.point", source: "test")
      end

      point = records.find { it[:event] == "kafka.point" }
      failure = Julewire.health.dig(:process_integrations, :karafka, :last_failure)

      assert_false point.fetch(:context).key?(:request_id)
      assert_equal :carrier_restore, failure.fetch(:action)
      assert_equal :message_context, failure.fetch(:component)
      assert_equal :malformed, failure.fetch(:status)
      assert_equal "carrier payload is not valid JSON", failure.fetch(:reason)
    end

    def test_with_message_restores_truncated_carrier_context
      records = capture_records

      Julewire::Karafka.with_message(karafka_message(headers: carrier_with_truncated_context, offsets: [42])) do
        Julewire.emit(event: "kafka.point", source: "test")
      end

      context = records.find { it[:event] == "kafka.point" }.fetch(:context)

      assert_truncated_context(context)
    end

    def test_with_message_ignores_non_hash_filtered_carrier
      point, = emit_with_carrier_filter(->(*) { "not-a-carrier" })

      assert_false point.fetch(:context).key?(:request_id)
      assert_equal "events", point.dig(:attributes, :karafka, :topic)
    end

    def test_carrier_for_returns_empty_carrier_for_non_hash_filter_results
      configuration = Julewire::Karafka::Configuration.new
      configuration.carrier_filter = ->(*) { "not-a-carrier" }

      carrier = Julewire::Karafka::MessageContext.__send__(
        :carrier_for,
        { topic: "events", headers: carrier_from_context("spoofed") },
        configuration
      )

      assert_equal({}, carrier)
    end

    def test_with_message_ignores_non_hash_filtered_carrier_objects
      encoded = Julewire::Core::Propagation::Carrier.encode(envelope: { context: { request_id: "leaked" } })
      fake_carrier = Object.new
      fake_carrier.define_singleton_method(:[]) { |key| key == "julewire" ? encoded : nil }

      point, = emit_with_carrier_filter(->(*) { fake_carrier })

      assert_false point.fetch(:context).key?(:request_id)
    end

    def test_with_message_ignores_non_hash_message_headers
      records = capture_records
      message = Julewire::KarafkaTestSupport::MutableMessage.new("events", 0, 42, "not-a-carrier")

      Julewire::Karafka.with_message(message) do
        Julewire.emit(event: "kafka.point", source: "test")
      end

      point = records.find { it[:event] == "kafka.point" }

      assert_false point.fetch(:context).key?(:request_id)
      assert_equal "not-a-carrier", point.dig(:attributes, :karafka, :headers)
    end

    def test_with_message_passes_empty_headers_to_filter_for_non_hash_headers
      records = capture_records
      configuration = Julewire::Karafka::Configuration.new
      configuration.carrier_filter = lambda { |headers, message:|
        assert_empty headers
        assert_equal "not-a-carrier", message.fetch(:headers)
        headers
      }
      message = Julewire::KarafkaTestSupport::MutableMessage.new("events", 0, 42, "not-a-carrier")

      Julewire::Karafka.with_message(message, configuration: configuration) do
        Julewire.emit(event: "kafka.point", source: "test")
      end

      point = records.find { it[:event] == "kafka.point" }

      assert_false point.fetch(:context).key?(:request_id)
    end

    def test_with_message_passes_empty_headers_to_filter_when_headers_are_absent
      records = capture_records
      configuration = Julewire::Karafka::Configuration.new
      configuration.carrier_filter = lambda { |headers, message:|
        assert_empty headers
        assert_equal "events", message.fetch(:topic)
        headers
      }

      Julewire::Karafka::MessageContext.call_fields(
        { topic: "events", partition: 0, offset: 42 },
        configuration: configuration
      ) do
        Julewire.emit(event: "kafka.point", source: "test")
      end

      point = records.find { it[:event] == "kafka.point" }

      assert_false point.fetch(:context).key?(:request_id)
      assert_false point.dig(:attributes, :karafka).key?(:headers)
    end

    def test_with_message_contains_carrier_filter_failures
      point, health = emit_with_carrier_filter(->(*) { raise "filter failed" })

      assert_false point.fetch(:context).key?(:request_id)
      assert_equal :carrier_filter, health.dig(:last_failure, :action)
      assert_equal :message_context, health.dig(:last_failure, :component)
      assert_equal "RuntimeError", health.dig(:last_failure, :class)
    end

    def test_carrier_for_returns_empty_carrier_after_filter_exception
      configuration = Julewire::Karafka::Configuration.new
      configuration.carrier_filter = ->(*) { raise "filter failed" }

      carrier = Julewire::Karafka::MessageContext.__send__(
        :carrier_for,
        { topic: "events", headers: carrier_from_context("spoofed") },
        configuration
      )
      health = Julewire.health.dig(:process_integrations, :karafka)

      assert_equal({}, carrier)
      assert_equal :carrier_filter, health.dig(:last_failure, :action)
      assert_equal :message_context, health.dig(:last_failure, :component)
      assert_equal "RuntimeError", health.dig(:last_failure, :class)
    end

    def test_with_message_context_is_captured_by_downstream_carrier_injection
      inbound_carrier = carrier_from_context("request-1")

      inbound = karafka_message(headers: inbound_carrier, offsets: [42])
      outbound = { headers: {} }

      Julewire::Karafka.with_message(inbound) do
        Julewire::Karafka.inject!(outbound)
      end

      envelope = Julewire::Core::Propagation::Carrier.extract_envelope(outbound.fetch(:headers))

      assert_equal "request-1", envelope.dig(:context, :request_id)
      assert_false envelope.fetch(:context).key?(:topic)
      assert_false envelope.fetch(:context).key?(:offset)
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
      envelope = Julewire::Core::Propagation::Carrier.extract_envelope(outbound.fetch(:headers))

      assert_message_execution_summary(summary)
      assert_equal "events:0:42", point.dig(:execution, :id)
      assert_equal "request-1", envelope.dig(:context, :request_id)
      assert_equal "events:0:42", envelope.dig(:execution, :id)
      assert_false envelope.fetch(:context).key?(:topic)
    end

    def test_with_message_execution_accepts_custom_execution_options
      records = capture_records
      configuration = Julewire::Karafka::Configuration.new
      configuration.source = "config-source"

      Julewire::Karafka.with_message_execution(
        karafka_message(offsets: [42]),
        configuration: configuration,
        type: :custom_message,
        id: "manual-id",
        summary_event: "custom.message.done",
        summary_severity: :warn,
        summary_source: "summary-source",
        shard: "a"
      ) do
        Julewire.emit(event: "kafka.message.processed", source: "test")
      end

      point = records.find { it[:event] == "kafka.message.processed" }
      summary = records.find { it[:event] == "custom.message.done" }

      assert_equal "custom_message", point.dig(:execution, :type)
      assert_equal "manual-id", point.dig(:execution, :id)
      assert_equal "a", point.dig(:execution, :shard)
      assert_equal :warn, summary.fetch(:severity)
      assert_equal "summary-source", summary.fetch(:source)
      assert_equal "custom_message", summary.dig(:execution, :type)
      assert_equal "manual-id", summary.dig(:execution, :id)
      assert_equal "a", summary.dig(:execution, :shard)
    end

    def test_with_message_execution_normalizes_string_keyed_options
      records = capture_records

      Julewire::Karafka.with_message_execution(
        karafka_message(offsets: [42]),
        **{
          "type" => :string_keyed_message,
          "id" => "string-id",
          "summary_event" => "string.message.done",
          "summary_source" => "string-source",
          "summary_severity" => :error,
          "batch" => "b"
        }
      ) do
        Julewire.emit(event: "kafka.message.processed", source: "test")
      end

      summary = records.find { it[:event] == "string.message.done" }

      assert_equal :error, summary.fetch(:severity)
      assert_equal "string-source", summary.fetch(:source)
      assert_equal "string_keyed_message", summary.dig(:execution, :type)
      assert_equal "string-id", summary.dig(:execution, :id)
      assert_equal "b", summary.dig(:execution, :batch)
    end

    def test_with_message_execution_omits_default_id_when_message_identity_is_incomplete
      records = capture_records

      [
        Julewire::KarafkaTestSupport::MutableMessage.new(nil, 0, 42, {}, key: :a),
        Julewire::KarafkaTestSupport::MutableMessage.new("events", nil, 42, {}, key: :a),
        Julewire::KarafkaTestSupport::MutableMessage.new("events", 0, nil, {}, key: :a)
      ].each do |message|
        Julewire::Karafka.with_message_execution(message, emit_summary: false) do
          Julewire.emit(event: "kafka.message.processed", source: "test")
        end
      end

      points = records.select { it[:event] == "kafka.message.processed" }

      assert_equal 3, points.size
      points.each { assert_match(/\A[0-9a-f-]{36}\z/, it.dig(:execution, :id)) }
    end

    def test_with_message_execution_can_skip_summary
      records = capture_records

      Julewire::Karafka.with_message_execution(
        karafka_message(offsets: [42]),
        emit_summary: false,
        summary_event: "custom.message.done"
      ) do
        Julewire.emit(event: "kafka.message.processed", source: "test")
      end

      assert_true(records.any? { it[:event] == "kafka.message.processed" })
      assert_false(records.any? { it[:event] == "custom.message.done" })
      assert_false(records.any? { it[:event] == "message.completed" })
    end

    def test_message_context_requires_block_and_can_skip_propagation
      configuration = Julewire::Karafka::Configuration.new
      configuration.propagation = false
      message = karafka_message(offsets: [42])

      with_message_error = assert_raises(ArgumentError) do
        Julewire::Karafka.with_message(message, configuration: configuration)
      end
      with_execution_error = assert_raises(ArgumentError) do
        Julewire::Karafka.with_message_execution(message, configuration: configuration)
      end

      assert_equal "block required", with_message_error.message
      assert_equal "block required", with_execution_error.message

      records = capture_records
      Julewire::Karafka.with_message(karafka_message(headers: carrier_from_context("ignored"), offsets: [42]),
                                     configuration: configuration) do
        Julewire.emit(event: "kafka.point", source: "test")

        assert_equal "events", Julewire.attributes[:karafka].fetch(:topic)
      end

      point = records.find { it[:event] == "kafka.point" }

      assert_false point.fetch(:context).key?(:request_id)
    end

    def test_disabled_propagation_skips_carrier_filter
      records = capture_records
      configuration = Julewire::Karafka::Configuration.new
      configuration.propagation = false
      configuration.carrier_filter = ->(*) { raise "filter should not run" }

      Julewire::Karafka.with_message(karafka_message(headers: carrier_from_context("ignored"), offsets: [42]),
                                     configuration: configuration) do
        Julewire.emit(event: "kafka.point", source: "test")
      end

      point = records.find { it[:event] == "kafka.point" }

      assert_false point.fetch(:context).key?(:request_id)
      assert_nil Julewire.health.dig(:process_integrations, :karafka, :last_failure)
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

    def carrier_with_truncated_context
      {
        "julewire" => Julewire::Core::Propagation::Carrier.encode(
          envelope: { context: { blob: "x" * 20_000 } }
        )
      }
    end

    def assert_truncated_context(context)
      assert_match(/\Ax+\.\.\.\[Truncated\]\z/, context.fetch(:blob))
      metadata = context.fetch(:_julewire_truncation)

      assert_true metadata.fetch(:truncated)
      assert_equal ["blob"], metadata.fetch(:truncated_fields)
      assert_equal Julewire::Core::Serialization::Serializer::DEFAULT_MAX_STRING_BYTES,
                   metadata.dig(:limits, :max_string_bytes)
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
        assert_false point.fetch(:context).key?(:request_id)
      end

      assert_equal "events", point.dig(:attributes, :karafka, :topic)
    end

    def assert_message_restores_request_context(carrier:, configuration:)
      point = message_point_for_carrier(carrier: carrier, configuration: configuration)

      assert_equal "request-1", point.dig(:context, :request_id)
    end

    def message_point_for_carrier(carrier:, configuration:)
      records = capture_records

      Julewire::Karafka.with_message(karafka_message(headers: carrier, offsets: [42]),
                                     configuration: configuration) do
        Julewire.emit(event: "kafka.point", source: "test")
      end

      records.find { it[:event] == "kafka.point" }
    end

    def assert_message_execution_summary(summary)
      assert_equal "karafka_message", summary.dig(:execution, :type)
      assert_equal "events:0:42", summary.dig(:execution, :id)
      assert_equal "request-1", summary.dig(:context, :request_id)
      assert_equal "karafka", summary.fetch(:source)
      assert_false summary.fetch(:context).key?(:topic)
      assert_equal "events", summary.dig(:neutral, :"messaging.destination.name")
      assert_equal 42, summary.dig(:attributes, :karafka, :offset)
    end
  end
end
