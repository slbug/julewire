# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "timeout"

module Julewire
  module SemanticLogger
    class TestSemanticLoggerTransport < Minitest::Test
      cover Julewire::SemanticLogger::AppenderHealth
      cover Julewire::SemanticLogger::ExactFormatter
      cover Julewire::SemanticLogger::LifecycleWarnings
      cover Julewire::SemanticLogger::Transport

      class GCPShapeFormatter
        def call(record)
          {
            severity: record.fetch(:severity).to_s.upcase,
            message: record.fetch(:message),
            labels: record.fetch(:labels, {}),
            jsonPayload: record.fetch(:payload, {})
          }
        end
      end

      class LineFormatter
        def call(record)
          { line: record.fetch(:message) }
        end
      end

      class FailingIO
        def write(_value)
          raise "write failed"
        end

        def flush; end
      end

      class FlakyIO
        attr_reader :string

        def initialize
          @failed = false
          @string = +""
        end

        def write(value)
          unless @failed
            @failed = true
            raise "write failed"
          end

          @string << value
        end

        def flush; end
      end

      class FailingLifecycleTransport
        def initialize(status: :ok)
          @status = status
        end

        def write(_payload, severity:); end

        def flush = raise("flush failed")

        def close = raise("close failed")

        def reopen = raise("reopen failed")

        def health = { status: @status }
      end

      class ForkAwareTransport
        attr_reader :after_fork_count

        def initialize
          @after_fork_count = 0
        end

        def write(_payload, severity:); end

        def flush; end

        def close; end

        def reopen; end

        def after_fork!
          @after_fork_count += 1
        end

        def health = { status: :ok }
      end

      class RaisingTransport
        def initialize(error)
          @error = error
        end

        def write(*, **) = raise @error

        def flush; end

        def close; end

        def health = { status: :ok }
      end

      class BlockingAppender < ::SemanticLogger::Subscriber
        attr_reader :concurrent

        def initialize
          super
          @mutex = Mutex.new
          @entries = Queue.new
          @releases = Queue.new
          @active = false
          @concurrent = false
        end

        def log(_log)
          @mutex.synchronize do
            @concurrent = true if @active
            @active = true
          end
          @entries << true
          @releases.pop
        ensure
          @mutex.synchronize { @active = false }
        end

        def wait_for_entry = Timeout.timeout(1) { @entries.pop }

        def entry_pending? = !@entries.empty?

        def release = @releases << true

        def flush; end

        def close; end
      end

      class RecordingAppender < ::SemanticLogger::Subscriber
        attr_reader :levels

        def initialize
          super
          @levels = []
        end

        def log(log)
          @levels << log.level
        end

        def flush; end

        def close; end
      end

      class RaisingAppender < ::SemanticLogger::Subscriber
        attr_reader :entries

        def initialize
          super
          @entries = Queue.new
        end

        def log(log)
          @entries << log
          raise "async appender failed"
        end

        def wait_for_entry = Timeout.timeout(1) { @entries.pop }

        def flush; end

        def close; end
      end
    end

    class TestSemanticLoggerDestination < Minitest::Test # rubocop:disable Metrics/ClassLength -- Adapter contract matrix.
      GCPShapeFormatter = TestSemanticLoggerTransport::GCPShapeFormatter
      LineFormatter = TestSemanticLoggerTransport::LineFormatter

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
        transport = Class.new do
          attr_reader :severity

          def write(_payload, severity:)
            @severity = severity
          end

          def flush; end

          def close; end

          def health = { status: :ok }
        end.new
        destination = Destination.new(name: :gcp, formatter: GCPShapeFormatter.new, transport: transport)

        Julewire.configure do |config|
          config.destinations.add(destination)
        end

        Julewire.warn("created")

        assert_equal :warn, transport.severity
      end

      def test_custom_destination_writes_core_encoded_payload_to_transport
        transport = Class.new do
          attr_reader :payload

          def write(payload, **)
            @payload = payload
          end

          def flush; end

          def close; end

          def health = { status: :ok }
        end.new
        destination = Destination.new(name: :gcp, formatter: GCPShapeFormatter.new, transport: transport)

        destination.emit(record(message: "created", severity: :info, payload: { id: 123 }))

        assert_instance_of String, transport.payload
        assert_equal "created", JSON.parse(transport.payload).fetch("message")
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
        io = TestSemanticLoggerTransport::FlakyIO.new
        destination = Destination.new(name: :semantic, formatter: LineFormatter.new, io: io, async: false)

        assert_nil destination.emit(record(message: "fail", severity: :info))
        assert_equal :degraded, destination.health.fetch(:status)

        destination.emit(record(message: "recover", severity: :info))
        health = destination.health

        assert_equal :ok, health.fetch(:status)
        assert_equal({ received: 2, formatted: 2, written: 1, failed: 1, callback_error: 0 }, health.fetch(:counts))
        assert_equal 1, health.dig(:transport, :counts, :failures)
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

        refute destination.flush
        assert_equal :degraded, destination.health.fetch(:status)

        assert destination.flush
        assert_equal :ok, destination.health.fetch(:status)
        assert_equal 2, transport.flushes
        expected_counts = { received: 0, formatted: 0, written: 0, failed: 1, callback_error: 0 }

        assert_equal expected_counts, destination.health.fetch(:counts)
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

      def test_custom_destination_satisfies_destination_chaos_contract
        Julewire::Testing::Chaos.assert_destination_chaos_contract(
          self,
          record: record(message: "chaos", severity: :info),
          formatter: ->(error) { formatter_chaos_destination(error) },
          encoder: ->(error) { encoder_chaos_destination(error) },
          output: ->(error) { transport_chaos_destination(error) },
          callbacks: ->(error) { callback_chaos_destination(error) }
        )
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

        assert Julewire.flush
        assert Julewire.close
      end

      def test_custom_destination_lifecycle_returns_false_on_failure
        destination = Destination.new(
          name: :semantic,
          formatter: LineFormatter.new,
          transport: TestSemanticLoggerTransport::FailingLifecycleTransport.new
        )

        refute destination.flush
        refute destination.close
        refute destination.reopen
        assert_equal :degraded, destination.health.fetch(:status)
        assert_equal 3, destination.health.dig(:counts, :failed)
      end

      def test_custom_destination_reflects_degraded_transport_status
        destination = Destination.new(
          name: :semantic,
          formatter: LineFormatter.new,
          transport: TestSemanticLoggerTransport::FailingLifecycleTransport.new(status: :degraded)
        )

        assert_equal :degraded, destination.health.fetch(:status)
      end

      def test_custom_destination_forwards_after_fork_to_transport
        transport = TestSemanticLoggerTransport::ForkAwareTransport.new
        destination = Destination.new(name: :semantic, formatter: LineFormatter.new, transport: transport)

        assert destination.after_fork!
        assert_equal 1, transport.after_fork_count
      end

      private

      def record(**fields)
        Core::Records::Draft.build(fields, context: {}, scope: nil).to_record
      end

      def formatter_chaos_destination(error)
        Destination.new(
          name: :semantic,
          formatter: Julewire::Testing::Chaos.raiser(error),
          io: StringIO.new,
          async: false
        )
      end

      def encoder_chaos_destination(error)
        Destination.new(
          name: :semantic,
          formatter: LineFormatter.new,
          encoder: Julewire::Testing::Chaos.raiser(error),
          io: StringIO.new,
          async: false
        )
      end

      def transport_chaos_destination(error)
        Destination.new(
          name: :semantic,
          formatter: LineFormatter.new,
          transport: TestSemanticLoggerTransport::RaisingTransport.new(error)
        )
      end

      def callback_chaos_destination(error)
        trigger = RuntimeError.new("format trigger")
        Destination.new(
          name: :semantic,
          formatter: Julewire::Testing::Chaos.raiser(trigger),
          io: StringIO.new,
          async: false,
          on_drop: Julewire::Testing::Chaos.raiser(error),
          on_failure: Julewire::Testing::Chaos.raiser(error)
        )
      end
    end

    class TestSemanticLoggerExactFormatter < Minitest::Test
      cover Julewire::SemanticLogger::ExactFormatter

      def test_uses_core_json_encoder_policy
        value = {
          message: "compact",
          context: {},
          payload: {},
          attributes: { rails: {} },
          false_value: false
        }
        log = ::SemanticLogger::Log.new(Transport::LOGGER_NAME, :info)
        log.assign(payload: { ExactFormatter::PAYLOAD_KEY => value })

        parsed = JSON.parse(ExactFormatter.new.call(log))

        assert_equal JSON.parse(Core::Serialization::JsonEncoder.new.call(value)), parsed
        refute parsed.fetch("false_value")
        refute_includes parsed, "context"
        refute_includes parsed, "payload"
        refute_includes parsed, "attributes"
      end

      def test_returns_mutable_string_payload_without_copy
        value = +"line"
        log = semantic_log(value)

        assert_same value, ExactFormatter.new.call(log)
      end

      def test_treats_string_subclasses_as_strings
        string_class = Class.new(String)
        value = string_class.new("line\n")
        log = semantic_log(value)

        assert_equal "line", ExactFormatter.new.call(log)
      end

      def test_duplicates_frozen_string_payload
        value = +"line"
        value.freeze
        log = semantic_log(value)

        result = ExactFormatter.new.call(log)

        assert_equal "line", result
        refute_same value, result
        refute_predicate result, :frozen?
      end

      def test_strips_semantic_logger_trailing_newline
        log = semantic_log("line\n")

        assert_equal "line", ExactFormatter.new.call(log)
      end

      def test_requires_exact_payload_key
        log = ::SemanticLogger::Log.new(Transport::LOGGER_NAME, :info)
        log.assign(payload: {})

        assert_raises(KeyError) { ExactFormatter.new.call(log) }
      end

      private

      def semantic_log(value)
        log = ::SemanticLogger::Log.new(Transport::LOGGER_NAME, :info)
        log.assign(payload: { ExactFormatter::PAYLOAD_KEY => value })
        log
      end
    end

    class TestSemanticLoggerTransportPrimitives < Minitest::Test
      cover Julewire::SemanticLogger::Transport

      LineFormatter = TestSemanticLoggerTransport::LineFormatter
      FailingIO = TestSemanticLoggerTransport::FailingIO

      def test_transport_defaults_to_sync_appender
        io = StringIO.new
        output = Transport.new(io: io)

        output.write({ severity: :info, message: "sync" }, severity: :info)
        output.flush

        assert_equal "sync", JSON.parse(io.string).fetch("message")
        refute output.health.fetch(:async)
        assert_equal "io", output.health.dig(:appender, :type)
        assert_empty warning_reasons(output)
      ensure
        output&.close
      end

      def test_async_transport_flushes_semantic_logger_queue
        io = StringIO.new
        output = Transport.new(io: io, async: true, max_queue_size: 100)

        output.write({ severity: :info, message: "queued" }, severity: :info)
        output.flush

        assert_equal "queued", JSON.parse(io.string).fetch("message")
        assert_equal :ok, output.health.fetch(:status)
        assert_equal "async", output.health.dig(:appender, :type)
        assert_equal 100, output.health.dig(:appender, :max_queue_size)
        assert_equal [:async_queue_blocks_when_full], warning_reasons(output)
      ensure
        output&.close
      end

      def test_transport_can_write_to_file_appender
        Dir.mktmpdir do |dir|
          path = File.join(dir, "julewire.log")
          output = Transport.new(file_name: path, async: false)

          output.write({ severity: :info, message: "file" }, severity: :info)
          output.flush

          assert_equal "file", JSON.parse(File.read(path)).fetch("message")
          assert_equal "file", output.health.dig(:appender, :type)
          assert_equal path, output.health.dig(:appender, :file_name)
        ensure
          output&.close
        end
      end

      def test_transport_writes_to_multiple_appenders
        first = StringIO.new
        second = StringIO.new
        output = Transport.new(
          appenders: [
            { io: first },
            { io: second }
          ],
          async: false
        )

        output.write({ severity: :info, message: "multi" }, severity: :info)
        output.flush

        assert_equal "multi", JSON.parse(first.string).fetch("message")
        assert_equal "multi", JSON.parse(second.string).fetch("message")
        assert_equal "multi_appender", output.health.dig(:appender, :type)
        assert_equal 2, output.health.dig(:appender, :appender_count)
        assert_equal [:sync_multi_appender_blocks_emitters], warning_reasons(output)
      ensure
        output&.close
      end

      def test_transport_accepts_appender_object_specs
        io = StringIO.new
        appender = ::SemanticLogger::Appender::IO.new(io, formatter: ExactFormatter.new)
        output = Transport.new(appenders: [appender], async: false)

        output.write({ severity: :info, message: "object appender" }, severity: :info)
        output.flush

        assert_equal "object appender", JSON.parse(io.string).fetch("message")
      ensure
        output&.close
      end

      def test_transport_accepts_single_appender_option
        io = StringIO.new
        appender = ::SemanticLogger::Appender::IO.new(io, formatter: ExactFormatter.new)
        output = Transport.new(appender: appender, async: false)

        output.write({ severity: :info, message: "single appender" }, severity: :info)
        output.reopen
        output.flush

        assert_equal "single appender", JSON.parse(io.string).fetch("message")
      ensure
        output&.close
      end

      def test_transport_after_fork_reopens_appenders
        io = StringIO.new
        output = Transport.new(io: io, async: true, max_queue_size: 100)

        output.after_fork!
        output.write({ severity: :info, message: "after fork" }, severity: :info)
        output.flush

        assert_equal "after fork", JSON.parse(io.string).fetch("message")
        assert_equal :ok, output.health.fetch(:status)
        assert output.health.dig(:appender, :active)
      ensure
        output&.close
      end

      def test_transport_maps_core_unknown_and_plain_values
        io = StringIO.new
        output = Transport.new(io: io, async: false)

        output.write({ severity: :unknown, message: "unknown" }, severity: :unknown)
        output.write("plain", severity: :info)
        output.flush

        unknown, plain = io.string.lines

        assert_equal "unknown", JSON.parse(unknown).fetch("message")
        assert_equal "plain\n", plain
      ensure
        output&.close
      end

      def test_transport_requires_authoritative_core_severity
        output = Transport.new(io: StringIO.new, async: false)

        assert_raises(ArgumentError) do
          output.write({ severity: :info, message: "missing" })
        end
      ensure
        output&.close
      end

      def test_transport_uses_authoritative_core_severity
        appender = TestSemanticLoggerTransport::RecordingAppender.new
        output = Transport.new(appender: appender, async: false)

        output.write({ message: "warn" }, severity: :warn)
        output.write({ message: "fatal" }, severity: :fatal)
        output.write({ message: "unknown" }, severity: :unknown)

        assert_equal %i[warn fatal fatal], appender.levels
      ensure
        output&.close
      end

      def test_unbounded_async_queue_is_reported_as_lifecycle_warning
        output = Transport.new(io: StringIO.new, async: true, max_queue_size: -1)

        assert_equal [:async_queue_unbounded], warning_reasons(output)
        refute output.health.dig(:appender, :capped)
      ensure
        output&.close
      end

      def test_transport_requires_a_sink
        error = assert_raises(ArgumentError) do
          Transport.new
        end

        assert_equal "semantic logger transport requires io, file_name, appender, or appenders", error.message
      end

      private

      def warning_reasons(output)
        output.health.fetch(:warnings).map { it.fetch(:reason) }
      end
    end

    class TestSemanticLoggerTransportAsyncFailure < Minitest::Test
      cover Julewire::SemanticLogger::Transport

      def test_async_transport_keeps_wrapped_appender_failures_inside_semantic_logger
        appender = TestSemanticLoggerTransport::RaisingAppender.new
        appender.logger.level = :fatal
        output = Transport.new(appender: appender, async: true, max_queue_size: 100)

        capture_io do
          output.write({ message: "queued" }, severity: :info)
          appender.wait_for_entry
          wait_for_async_appender(output)
        end

        assert_equal :ok, output.health.fetch(:status)
        assert_equal({ writes: 1, failures: 0 }, output.health.fetch(:counts))
        assert output.health.dig(:appender, :active)
      ensure
        output&.close
      end

      private

      def wait_for_async_appender(output)
        Timeout.timeout(1) do
          Thread.pass until output.health.dig(:appender, :active) && output.health.dig(:appender, :queue_size).zero?
        end
      end
    end

    class TestSemanticLoggerTransportConcurrency < Minitest::Test
      cover Julewire::SemanticLogger::Transport

      def test_sync_transport_serializes_appender_log_calls
        appender = TestSemanticLoggerTransport::BlockingAppender.new
        output = Transport.new(appender: appender, async: false)

        first = Thread.new { output.write({ message: "first" }, severity: :info) }
        appender.wait_for_entry
        second = start_blocked_write(output, "second")

        refute appender.concurrent
        refute_predicate appender, :entry_pending?

        appender.release
        appender.wait_for_entry
        appender.release
        [first, second].each(&:value)

        refute appender.concurrent
      ensure
        2.times { appender&.release }
        [first, second].compact.each { it.join(1) }
        output&.close
      end

      private

      def wait_until_sleeping(thread)
        Timeout.timeout(1) do
          Thread.pass until thread.status == "sleep"
        end
      end

      def start_blocked_write(output, message)
        started = Queue.new
        thread = Thread.new do
          started << true
          output.write({ message: message }, severity: :info)
        end
        started.pop
        wait_until_sleeping(thread)
        thread
      end
    end

    class TestSemanticLoggerTransportAppenderSpecs < Minitest::Test
      cover Julewire::SemanticLogger::Transport

      def test_transport_accepts_single_hash_appender_spec
        io = StringIO.new
        output = Transport.new(appenders: { io: io }, async: false)

        output.write({ severity: :info, message: "single hash" }, severity: :info)
        output.flush

        assert_equal "single hash", JSON.parse(io.string).fetch("message")
      ensure
        output&.close
      end
    end

    class TestSemanticLoggerTransportFailures < Minitest::Test
      cover Julewire::SemanticLogger::Transport

      LineFormatter = TestSemanticLoggerTransport::LineFormatter
      FailingIO = TestSemanticLoggerTransport::FailingIO

      def test_transport_counts_and_reraises_write_failures
        output = Transport.new(io: FailingIO.new, async: false)

        error = assert_raises(RuntimeError) do
          output.write({ severity: :info, message: "fail" }, severity: :info)
        end

        assert_equal "write failed", error.message
        assert_equal :degraded, output.health.fetch(:status)
        assert_equal({ writes: 1, failures: 1 }, output.health.fetch(:counts))
      ensure
        output&.close
      end

      def test_transport_degraded_status_recovers_after_successful_write
        output = Transport.new(io: TestSemanticLoggerTransport::FlakyIO.new, async: false)

        assert_raises(RuntimeError) do
          output.write({ message: "fail" }, severity: :info)
        end
        assert_equal :degraded, output.health.fetch(:status)

        output.write({ message: "recover" }, severity: :info)

        assert_equal :ok, output.health.fetch(:status)
        assert_equal({ writes: 2, failures: 1 }, output.health.fetch(:counts))
      ensure
        output&.close
      end

      def test_appender_health_reports_generic_appenders
        health = AppenderHealth.call(Object.new)

        assert_equal "appender", health.fetch(:type)
      end

      def test_destination_contains_transport_write_failures
        destination = Destination.new(
          name: :semantic,
          formatter: LineFormatter.new,
          io: FailingIO.new,
          async: false
        )

        assert_nil destination.emit(record(message: "fail", severity: :info))

        health = destination.health

        assert_equal :degraded, health.fetch(:status)
        assert_equal({ received: 1, formatted: 1, written: 0, failed: 1, callback_error: 0 }, health.fetch(:counts))
        assert_equal 1, health.dig(:transport, :counts, :failures)
      ensure
        destination&.close
      end

      def test_destination_serializes_non_json_safe_formatter_output
        destination = Destination.new(
          name: :semantic,
          formatter: ->(_record) { { message: "bad", value: Float::NAN } },
          io: StringIO.new,
          async: false
        )

        destination.emit(record(message: "bad", severity: :info))

        assert_equal :ok, destination.health.fetch(:status)
        assert_equal(
          { received: 1, formatted: 1, written: 1, failed: 0, callback_error: 0 },
          destination.health.fetch(:counts)
        )
      ensure
        destination&.close
      end

      private

      def record(**fields)
        Core::Records::Draft.build(fields, context: {}, scope: nil).to_record
      end
    end
  end
end
