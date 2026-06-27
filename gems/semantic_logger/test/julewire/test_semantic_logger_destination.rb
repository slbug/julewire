# frozen_string_literal: true

require "test_helper"
require_relative "support/semantic_logger_transport_fixtures"

module Julewire
  module SemanticLogger
    class TestSemanticLoggerDestination < Minitest::Test
      class ConcurrentLifecycleTransport
        attr_reader :flush_started, :release_flush

        def initialize
          @flush_started = Queue.new
          @release_flush = Queue.new
        end

        def write(*) = raise "concurrent write failed"

        def flush
          @flush_started << true
          @release_flush.pop
        end

        def close; end

        def health = { status: :ok }
      end

      cover Julewire::SemanticLogger::Destination
      GCPShapeFormatter = SemanticLoggerTransportFixtures::GCPShapeFormatter
      LineFormatter = SemanticLoggerTransportFixtures::LineFormatter

      def test_custom_destination_transports_hash_shape_without_semantic_logger_fields
        io = StringIO.new
        formatter = GCPShapeFormatter.new
        destination = Destination.new(
          name: :gcp,
          formatter: formatter,
          io: io,
          async: false
        )

        Julewire.configure do |config|
          config.destinations.add(destination)
        end

        Julewire.emit(message: "created", payload: { id: 123 }, labels: { tenant: "t1" })
        Julewire.flush

        parsed = JSON.parse(io.string)

        assert_equal "INFO", parsed.fetch("severity")
        assert_equal "created", parsed.fetch("message")
        assert_equal({ "id" => 123 }, parsed.fetch("jsonPayload"))
        assert_equal({ "tenant" => "t1" }, parsed.fetch("labels"))
        refute_includes parsed.keys, "payload"
        refute_includes parsed.keys, "named_tags"
        refute_includes parsed.keys, "name"
      end

      def test_custom_destination_passes_core_severity_to_transport
        transport = capturing_transport
        destination = Destination.new(name: :gcp, formatter: GCPShapeFormatter.new, transport: transport)

        Julewire.configure do |config|
          config.destinations.add(destination)
        end

        Julewire.warn("created")

        assert_equal :warn, transport.severity
      end

      def test_custom_destination_writes_core_encoded_payload_to_transport
        transport = capturing_transport
        destination = Destination.new(name: :gcp, formatter: GCPShapeFormatter.new, transport: transport)

        destination.emit(record(message: "created", severity: :info, payload: { id: 123 }))

        assert_instance_of String, transport.payload
        assert_equal "created", JSON.parse(transport.payload).fetch("message")
      end

      def test_custom_destination_preserves_string_formatter_output
        string_class = Class.new(String)
        transport = capturing_transport
        destination = Destination.new(
          name: :semantic,
          formatter: ->(_record) { string_class.new("already encoded") },
          encoder: ->(_payload) { raise "encoder should not run" },
          transport: transport
        )

        destination.emit(record(message: "created", severity: :info))

        assert_equal "already encoded", transport.payload
      end

      def test_custom_destination_normalizes_string_names_and_exposes_transport_identity
        transport = SemanticLoggerTransportFixtures::ForkAwareTransport.new
        destination = Destination.new(name: "semantic", formatter: LineFormatter.new, transport: transport)

        assert_equal :semantic, destination.name
        assert_same transport, destination.resource_identity
      end

      def test_custom_destination_receives_core_symbol_key_snapshot
        io = StringIO.new
        observed = nil
        formatter = lambda do |record|
          observed = record
          { message: record.fetch(:message), labels: record.fetch(:labels) }
        end
        destination = Destination.new(name: :semantic, formatter: formatter, io: io, async: false)

        Julewire.configure do |config|
          config.destinations.add(destination)
        end

        Julewire.emit("message" => "created", "labels" => { "tenant" => "t1" })
        Julewire.flush

        assert_predicate observed, :frozen?
        assert_equal "created", observed.fetch(:message)
        assert_equal({ tenant: "t1" }, observed.fetch(:labels))
        refute_includes observed, "payload"
        assert_equal({ "tenant" => "t1" }, JSON.parse(io.string).fetch("labels"))
      end

      def test_custom_destination_records_formatter_failures_in_adapter_health
        output = StringIO.new
        formatter = ->(_record) { raise "format failed" }
        destination = Destination.new(name: :semantic, formatter: formatter, io: output, async: false)

        Julewire.configure do |config|
          config.destinations.add(destination)
        end

        Julewire.emit(message: "lost")

        health = Julewire.health.dig(:pipeline, :destinations, :semantic)

        assert_empty output.string
        assert_equal :degraded, health.fetch(:status)
        assert_equal({ received: 1, formatted: 0, written: 0, failed: 1, callback_error: 0 }, health.fetch(:counts))
      end

      def test_custom_destination_degraded_status_recovers_after_successful_write
        io = SemanticLoggerTransportFixtures::FlakyIO.new
        destination = Destination.new(name: :semantic, formatter: LineFormatter.new, io: io, async: false)

        assert_nil destination.emit(record(message: "fail", severity: :info))
        assert_equal :degraded, destination.health.fetch(:status)

        destination.emit(record(message: "recover", severity: :info))
        health = destination.health

        assert_equal :ok, health.fetch(:status)
        assert_equal({ received: 2, formatted: 2, written: 1, failed: 1, callback_error: 0 }, health.fetch(:counts))
        assert_equal 1, health.dig(:transport, :counts, :failures)
        assert_equal "RuntimeError", health.dig(:last_failure, :class)
        assert_equal "RuntimeError", health.dig(:transport, :last_failure, :class)
      ensure
        destination&.close
      end

      def test_custom_destination_reports_write_failure_metadata_to_health_and_callbacks
        failures = []
        drops = []
        destination = Destination.new(
          name: :"semantic.logger",
          formatter: LineFormatter.new,
          io: SemanticLoggerTransportFixtures::FailingIO.new,
          async: false,
          on_failure: ->(error, metadata) { failures << [error, metadata] },
          on_drop: ->(reason, metadata) { drops << [reason, metadata] }
        )
        failed_record = record(message: "fail", severity: :error, labels: { tenant: "t1" })

        destination.emit(failed_record)

        health = destination.health
        failure = health.fetch(:last_failure)

        assert_equal :"semantic.logger", destination.name
        assert_equal "RuntimeError", failure.fetch(:class)
        assert_equal destination.name, failure.fetch(:destination)
        assert_equal :destination, failure.fetch(:phase)
        assert_equal({ event: "log", severity: :error, labels: { tenant: "t1" } }, failure.fetch(:record))
        assert_equal 1, failures.length
        assert_equal "write failed", failures.dig(0, 0).message
        assert_equal destination.name, failures.dig(0, 1, :destination)
        assert_equal :destination, failures.dig(0, 1, :phase)
        assert_instance_of Hash, failures.dig(0, 1, :record_metadata)
        assert_equal :error, failures.dig(0, 1, :record_metadata, :severity)
        assert_equal([[:destination_exception, destination.name, :destination, :destination_exception, :error]],
                     drops.map do |reason, metadata|
                       assert_instance_of Hash, metadata.fetch(:record_metadata)
                       [
                         reason,
                         metadata.fetch(:destination),
                         metadata.fetch(:phase),
                         metadata.fetch(:reason),
                         metadata.dig(:record_metadata, :severity)
                       ]
                     end)
      ensure
        destination&.close
      end

      def test_custom_destination_records_callback_failures
        destination = Destination.new(
          name: :semantic,
          formatter: LineFormatter.new,
          io: SemanticLoggerTransportFixtures::FailingIO.new,
          async: false,
          on_failure: ->(_error, _metadata) { raise "callback failed" },
          on_drop: ->(_reason, _metadata) { raise "drop callback failed" }
        )

        destination.emit(record(message: "fail", severity: :error))

        health = destination.health

        assert_equal 2, health.dig(:counts, :callback_error)
        assert_equal "RuntimeError", health.dig(:last_callback_failure, :class)
        assert_equal :semantic, health.dig(:last_callback_failure, :destination)
        assert_equal :destination, health.dig(:last_callback_failure, :phase)
        assert_equal :destination_exception, health.dig(:last_callback_failure, :reason)
      ensure
        destination&.close
      end

      def test_custom_destination_records_on_failure_callback_failure_without_drop_callback
        destination = Destination.new(
          name: :semantic,
          formatter: ->(_record) { raise "format failed" },
          io: StringIO.new,
          async: false,
          on_failure: ->(_error, _metadata) { raise "callback failed" }
        )

        destination.emit(record(message: "fail", severity: :error))

        health = destination.health

        assert_equal 1, health.dig(:counts, :callback_error)
        assert_equal "RuntimeError", health.dig(:last_callback_failure, :class)
        assert_equal :semantic, health.dig(:last_callback_failure, :destination)
        assert_equal :destination, health.dig(:last_callback_failure, :phase)
      ensure
        destination&.close
      end

      def test_custom_destination_degraded_status_recovers_after_successful_lifecycle_call
        transport = Class.new do
          attr_reader :flushes

          def initialize
            @failed = false
            @flushes = 0
          end

          def write(_payload, severity:); end

          def flush
            @flushes += 1
            return if @failed

            @failed = true
            raise "flush failed"
          end

          def close; end

          def health = { status: :ok }
        end.new
        destination = Destination.new(name: :semantic, formatter: LineFormatter.new, transport: transport)

        assert_false destination.flush
        assert_equal :degraded, destination.health.fetch(:status)

        assert_true destination.flush
        assert_equal :ok, destination.health.fetch(:status)
        assert_equal 2, transport.flushes
        expected_counts = { received: 0, formatted: 0, written: 0, failed: 1, callback_error: 0 }

        assert_equal expected_counts, destination.health.fetch(:counts)
        assert_equal "RuntimeError", destination.health.dig(:last_failure, :class)
      end

      def test_successful_lifecycle_reports_success_without_erasing_concurrent_degradation
        transport = ConcurrentLifecycleTransport.new
        destination = Destination.new(name: :semantic, formatter: LineFormatter.new, transport: transport)
        flush_thread = safe_thread { destination.flush }
        safe_queue_pop(transport.flush_started)

        destination.emit(record(message: "lost", severity: :error))
        transport.release_flush << true

        assert_true safe_thread_value(flush_thread)
        assert_equal :degraded, destination.health.fetch(:status)
        assert_equal "RuntimeError", destination.health.dig(:last_failure, :class)
      ensure
        transport&.release_flush&.push(true) if flush_thread&.alive?
        cleanup_thread(flush_thread)
      end

      def test_custom_destination_contains_formatter_signature_errors
        output = StringIO.new
        formatter = -> { { message: "missing record" } }
        destination = Destination.new(name: :semantic, formatter: formatter, io: output, async: false)

        Julewire.configure do |config|
          config.destinations.add(destination)
        end

        Julewire.emit(message: "lost")

        assert_empty output.string
        assert_equal :degraded, Julewire.health.dig(:pipeline, :destinations, :semantic, :status)
        assert_equal(
          { received: 1, formatted: 0, written: 0, failed: 1, callback_error: 0 },
          Julewire.health.dig(:pipeline, :destinations, :semantic, :counts)
        )
      end

      def test_custom_destination_direct_health_reports_formatter_degradation
        destination = Destination.new(
          name: :semantic,
          formatter: ->(_record) { raise "format failed" },
          io: StringIO.new,
          async: false
        )

        destination.emit(record(message: "lost", severity: :info))

        assert_equal :degraded, destination.health.fetch(:status)
      ensure
        destination&.close
      end

      def test_custom_destination_status_tracks_closed_transport
        destination = Destination.new(name: :semantic, formatter: LineFormatter.new, io: StringIO.new, async: false)

        destination.close

        assert_equal :closed, destination.health.fetch(:status)
      end

      def test_custom_destination_lifecycle_returns_truthy_on_success
        destination = Destination.new(name: :semantic, formatter: LineFormatter.new, io: StringIO.new, async: false)

        Julewire.configure do |config|
          config.destinations.add(destination)
        end

        assert_true Julewire.flush
        assert_true Julewire.close
      end

      def test_custom_destination_lifecycle_returns_false_on_failure
        failures = []
        destination = Destination.new(
          name: :semantic,
          formatter: LineFormatter.new,
          transport: SemanticLoggerTransportFixtures::FailingLifecycleTransport.new,
          on_failure: ->(error, metadata) { failures << [error, metadata] }
        )

        assert_false destination.flush
        assert_false destination.close
        assert_false destination.reopen
        assert_equal :degraded, destination.health.fetch(:status)
        assert_equal 3, destination.health.dig(:counts, :failed)
        assert_equal(%i[flush close reopen], failures.map { |(_error, metadata)| metadata.fetch(:action) })
        assert_equal(%i[destination_lifecycle destination_lifecycle destination_lifecycle],
                     failures.map { |(_error, metadata)| metadata.fetch(:phase) })
        assert_equal(%i[semantic semantic semantic], failures.map { |(_error, metadata)| metadata.fetch(:destination) })
        assert_equal(["flush failed", "close failed", "reopen failed"],
                     failures.map { |(error, _metadata)| error.message })
        assert_equal "RuntimeError", destination.health.dig(:last_failure, :class)
        assert_equal :semantic, destination.health.dig(:last_failure, :destination)
        assert_equal :reopen, destination.health.dig(:last_failure, :action)
        assert_equal :destination_lifecycle, destination.health.dig(:last_failure, :phase)
      end

      def test_custom_destination_reflects_degraded_transport_status
        destination = Destination.new(
          name: :semantic,
          formatter: LineFormatter.new,
          transport: SemanticLoggerTransportFixtures::FailingLifecycleTransport.new(status: :degraded)
        )

        assert_equal :degraded, destination.health.fetch(:status)
      end

      def test_custom_destination_treats_missing_transport_status_as_ok
        transport = Class.new do
          def write(_payload, severity:); end

          def flush; end

          def close; end

          def health = {}
        end.new
        destination = Destination.new(name: :semantic, formatter: LineFormatter.new, transport: transport)

        assert_equal :ok, destination.health.fetch(:status)
      end

      def test_custom_destination_forwards_after_fork_to_transport
        transport = SemanticLoggerTransportFixtures::ForkAwareTransport.new
        destination = Destination.new(name: :semantic, formatter: LineFormatter.new, transport: transport)

        assert_true destination.after_fork!
        assert_equal 1, transport.after_fork_count
      end

      def test_custom_destination_reports_after_fork_failures
        destination, failures = destination_with_failure_capture(
          SemanticLoggerTransportFixtures::FailingAfterForkTransport.new
        )

        assert_false destination.after_fork!

        assert_equal "after fork failed", failures.dig(0, 0).message
        assert_equal :after_fork, failures.dig(0, 1, :action)
        assert_equal :destination_lifecycle, failures.dig(0, 1, :phase)
        assert_equal :after_fork, destination.health.dig(:last_failure, :action)
      end

      def test_custom_destination_validates_callbacks
        assert_invalid_callback(:on_drop)
        assert_invalid_callback(:on_failure)
      end

      private

      def destination_with_failure_capture(transport)
        failures = []
        destination = Destination.new(
          name: :semantic,
          formatter: LineFormatter.new,
          transport:,
          on_failure: ->(error, metadata) { failures << [error, metadata] }
        )

        [destination, failures]
      end

      def assert_invalid_callback(name)
        options = { name: :semantic, formatter: LineFormatter.new, io: StringIO.new, name => Object.new }
        error = assert_raises(ArgumentError) do
          Destination.new(**options)
        end

        assert_equal "#{name} must respond to #call", error.message
      end

      def record(**fields)
        Core::Records::Draft.build(fields, context: {}, scope: nil).to_record
      end

      def capturing_transport
        Class.new do
          attr_reader :payload, :severity

          def write(payload, severity: nil, **)
            @payload = payload
            @severity = severity
          end

          def flush; end

          def close; end

          def health = { status: :ok }
        end.new
      end
    end
  end
end
