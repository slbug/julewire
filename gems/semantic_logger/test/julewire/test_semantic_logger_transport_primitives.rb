# frozen_string_literal: true

require "test_helper"
require_relative "support/semantic_logger_transport_fixtures"

module Julewire
  module SemanticLogger
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
        assert_false parsed.fetch("false_value")
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
      cover "Julewire::SemanticLogger::Transport#write"
      cover "Julewire::SemanticLogger::AppenderHealth.file_health"
      cover "Julewire::SemanticLogger::AppenderHealth.async_health"
      cover "Julewire::SemanticLogger::AppenderHealth.collection_health"
      LineFormatter = SemanticLoggerTransportFixtures::LineFormatter
      FailingIO = SemanticLoggerTransportFixtures::FailingIO

      def test_transport_defaults_to_sync_appender
        io = StringIO.new
        output = Transport.new(io: io)

        assert_equal :ok, output.health.fetch(:status)
        assert_false output.health.fetch(:async)
        output.write({ severity: :info, message: "sync" }, severity: :info)
        output.flush

        assert_equal "sync", JSON.parse(io.string).fetch("message")
        assert_equal "io", output.health.dig(:appender, :type)
        assert_empty warning_reasons(output)
      ensure
        output&.close
      end

      def test_async_transport_flushes_semantic_logger_queue
        io = StringIO.new
        output = Transport.new(io: io, async: true, max_queue_size: 100)

        output.write({ severity: :info, message: "queued" }, severity: :info)
        Timeout.timeout(SemanticLoggerTransportFixtures::ASYNC_TEST_TIMEOUT) { output.flush }

        assert_equal "queued", JSON.parse(io.string).fetch("message")
        assert_equal :ok, output.health.fetch(:status)
        assert_equal "async", output.health.dig(:appender, :type)
        assert_equal 100, output.health.dig(:appender, :max_queue_size)
        assert_equal 1_000, output.health.dig(:appender, :lag_check_interval)
        assert_equal 30, output.health.dig(:appender, :lag_threshold_s)
        assert_equal "io", output.health.dig(:appender, :wrapped, :type)
        assert_equal [:async_queue_blocks_when_full], warning_reasons(output)
      ensure
        output&.close
      end

      def test_async_transport_delivers_log_to_wrapped_appender
        appender = SemanticLoggerTransportFixtures::CapturingAppender.new
        output = Transport.new(appender: appender, async: true, max_queue_size: 100)

        output.write({ message: "queued", payload: { id: 123 } }, severity: :error)
        log = appender.wait_for_entry

        assert_instance_of ::SemanticLogger::Log, log
        assert_equal :error, log.level
        assert_equal Transport::LOGGER_NAME, log.name
        assert_equal({ message: "queued", payload: { id: 123 } }, log.payload.fetch(ExactFormatter::PAYLOAD_KEY))
      ensure
        output&.close
      end

      def test_async_transport_reports_custom_lag_options
        output = Transport.new(
          io: StringIO.new,
          async: true,
          max_queue_size: 100,
          lag_check_interval: 123,
          lag_threshold_s: 4
        )

        assert_equal 123, output.health.dig(:appender, :lag_check_interval)
        assert_equal 4, output.health.dig(:appender, :lag_threshold_s)
      ensure
        output&.close
      end

      def test_async_transport_forwards_semantic_logger_v5_queue_options
        return unless semantic_logger_v5_async_options?

        output = Transport.new(
          io: StringIO.new,
          async: true,
          max_queue_size: 100,
          non_blocking: true,
          dropped_message_report_seconds: 7,
          async_max_retries: 3
        )
        appender = output.send(:appender)

        assert_predicate appender, :non_blocking?
        assert_equal 3, appender.processor.async_max_retries
        assert_equal 7, appender.processor.dropped_message_report_seconds
      ensure
        output&.close
      end

      def test_batch_transport_uses_semantic_logger_batch_proxy
        appender = SemanticLoggerTransportFixtures::BatchingAppender.new
        output = Transport.new(
          appender: appender,
          batch: true,
          batch_size: 2,
          batch_seconds: 60,
          max_queue_size: 100
        )

        output.write({ message: "first" }, severity: :info)
        output.write({ message: "second" }, severity: :info)
        batch = appender.wait_for_batch
        messages = batch.map { it.payload.fetch(ExactFormatter::PAYLOAD_KEY).fetch(:message) }

        assert_true output.health.fetch(:async)
        assert_equal %w[first second], messages
      ensure
        output&.close
      end

      def test_async_transport_reports_default_queue_capacity
        output = Transport.new(io: StringIO.new, async: true)

        assert_equal Transport::DEFAULT_MAX_QUEUE_SIZE, output.health.dig(:appender, :max_queue_size)
      ensure
        output&.close
      end

      def test_async_transport_reports_degraded_when_appender_is_inactive
        output = Transport.new(io: StringIO.new, async: true)

        output.send(:appender).close

        assert_equal :degraded, output.health.fetch(:status)
        assert_nil output.health.dig(:appender, :active)
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
          assert_equal path, output.health.dig(:appender, :current_file_name)
          assert_equal 1, output.health.dig(:appender, :log_count)
          assert_operator output.health.dig(:appender, :log_size), :>, 0
          assert_nil output.health.dig(:appender, :reopen_at)
        ensure
          output&.close
        end
      end

      def test_transport_reports_rotating_file_reopen_at
        Dir.mktmpdir do |dir|
          path = File.join(dir, "julewire.log")
          output = Transport.new(file_name: path, reopen_period: "1m", async: false)

          output.write({ severity: :info, message: "file" }, severity: :info)
          output.flush

          health = output.health.fetch(:appender)

          assert_includes health, :reopen_at
          assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/, health.fetch(:reopen_at))
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
        assert_equal(%w[io io], output.health.dig(:appender, :appenders).map { it.fetch(:type) })
        assert_equal([0, 1], output.health.dig(:appender, :appenders).map { it.fetch(:index) })
        assert_equal [:sync_multi_appender_blocks_emitters], warning_reasons(output)
      ensure
        output&.close
      end

      def test_transport_accepts_hash_subclass_appender_spec
        io = StringIO.new
        spec = Class.new(Hash).new.merge(io: io)
        output = Transport.new(appenders: spec, async: false)

        output.write({ severity: :info, message: "hash subclass" }, severity: :info)
        output.flush

        assert_equal "hash subclass", JSON.parse(io.string).fetch("message")
      ensure
        output&.close
      end

      def test_transport_does_not_mutate_appender_specs
        first = StringIO.new
        second = StringIO.new
        specs = [{ io: first }]
        output = Transport.new(appenders: specs, io: second, async: false)

        assert_equal 1, specs.length

        output.write({ severity: :info, message: "immutable specs" }, severity: :info)
        output.flush

        assert_equal "immutable specs", JSON.parse(first.string).fetch("message")
        assert_equal "immutable specs", JSON.parse(second.string).fetch("message")
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

        output.close

        assert_equal :closed, output.health.fetch(:status)

        output.after_fork!
        output.write({ severity: :info, message: "after fork" }, severity: :info)
        Timeout.timeout(SemanticLoggerTransportFixtures::ASYNC_TEST_TIMEOUT) { output.flush }

        assert_equal "after fork", JSON.parse(io.string).fetch("message")
        assert_equal :ok, output.health.fetch(:status)
        assert_true output.health.dig(:appender, :active)
      ensure
        output&.close
      end

      def test_transport_reopen_is_optional_and_reopens_state
        appender = SemanticLoggerTransportFixtures::ReopenlessAppender.new
        output = Transport.new(appender: appender, async: false)

        output.close

        assert_true appender.closed
        assert_equal :closed, output.health.fetch(:status)

        output.reopen

        assert_equal :ok, output.health.fetch(:status)
      ensure
        output&.close
      end

      def test_transport_reopen_clears_degraded_state
        output = Transport.new(io: FailingIO.new, async: false)

        assert_raises(RuntimeError) do
          output.write({ message: "fail" }, severity: :info)
        end
        assert_equal :degraded, output.health.fetch(:status)

        assert_nil output.reopen
        assert_equal :ok, output.health.fetch(:status)
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
        appender = SemanticLoggerTransportFixtures::RecordingAppender.new
        output = Transport.new(appender: appender, async: false)

        output.write({ message: "warn" }, severity: :warn)
        output.write({ message: "fatal" }, severity: :fatal)
        output.write({ message: "unknown" }, severity: :unknown)
        output.write({ message: "output severity" }, severity: "ERROR")
        output.write({ message: "bad severity" }, severity: Object.new)

        assert_equal %i[warn fatal fatal info info], appender.levels
      ensure
        output&.close
      end

      def test_transport_uses_julewire_logger_name
        appender = SemanticLoggerTransportFixtures::RecordingAppender.new
        output = Transport.new(appender: appender, async: false)

        output.write({ message: "named" }, severity: :info)

        assert_equal [Transport::LOGGER_NAME], appender.names
      ensure
        output&.close
      end

      def test_transport_defaults_nil_severity_to_info
        appender = SemanticLoggerTransportFixtures::RecordingAppender.new
        output = Transport.new(appender: appender, async: false)

        output.write({ message: "nil severity" }, severity: nil)

        assert_equal [:info], appender.levels
      ensure
        output&.close
      end

      def test_transport_merges_defaults_into_hash_appender_specs
        io = StringIO.new
        formatter = Class.new do
          def call(*)
            +"default formatter"
          end
        end.new
        output = Transport.new(appenders: [{ io: io }], formatter: formatter, async: false)

        output.write({ message: "info" }, severity: :info)
        output.flush

        assert_equal "default formatter\n", io.string
      ensure
        output&.close
      end

      def test_transport_suppresses_nested_appender_async
        io = StringIO.new
        output = Transport.new(appenders: [{ io: io, async: true }], async: false)

        assert_equal "io", output.health.dig(:appender, :type)
      ensure
        output&.close
      end

      def test_unbounded_async_queue_is_reported_as_lifecycle_warning
        output = Transport.new(io: StringIO.new, async: true, max_queue_size: -1)

        assert_equal [:async_queue_unbounded], warning_reasons(output)
        assert_false output.health.dig(:appender, :capped)
      ensure
        output&.close
      end

      def test_transport_requires_a_sink
        error = assert_raises(ArgumentError) do
          Transport.new
        end

        assert_equal "semantic logger transport requires io, file_name, appender, or appenders", error.message
      end

      def test_transport_reports_full_health_shape
        output = Transport.new(io: StringIO.new, async: false)

        output.write({ message: "health" }, severity: :info)
        health = output.health

        assert_equal "semantic_logger", health.fetch(:type)
        assert_equal :ok, health.fetch(:status)
        assert_false health.fetch(:async)
        assert_equal({ writes: 1, failures: 0 }, health.fetch(:counts))
        assert_equal "io", health.dig(:appender, :type)
        assert_equal 1, health.fetch(:appenders).length
        assert_equal 0, health.dig(:appenders, 0, :index)
        assert_equal "io", health.dig(:appenders, 0, :type)
        assert_equal "SemanticLogger::Appender::IO", health.dig(:appenders, 0, :appender_class)
      ensure
        output&.close
      end

      def test_transport_lifecycle_returns_nil
        output = Transport.new(io: StringIO.new, async: false)

        assert_nil output.flush
        assert_nil output.close
        assert_nil output.reopen
      ensure
        output&.close
      end

      private

      def warning_reasons(output)
        output.health.fetch(:warnings).map { it.fetch(:reason) }
      end

      def semantic_logger_v5_async_options?
        ::SemanticLogger::Appender::Async.instance_method(:initialize).parameters.any? { |kind, _name| kind == :keyrest }
      end
    end
  end
end
