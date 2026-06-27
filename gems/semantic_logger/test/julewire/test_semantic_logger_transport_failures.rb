# frozen_string_literal: true

require "test_helper"
require_relative "support/semantic_logger_transport_fixtures"

module Julewire
  module SemanticLogger
    class TestSemanticLoggerTransportAsyncFailure < Minitest::Test
      cover "Julewire::SemanticLogger::Transport#write"
      def test_async_transport_keeps_wrapped_appender_failures_inside_semantic_logger
        appender = SemanticLoggerTransportFixtures::RaisingAppender.new
        appender.logger.level = :fatal
        output = Transport.new(appender: appender, async: true, max_queue_size: 100)

        capture_io do
          output.write({ message: "queued" }, severity: :info)
          appender.wait_for_entry
          wait_for_async_appender(output)
        end

        assert_equal :ok, output.health.fetch(:status)
        assert_equal({ writes: 1, failures: 0 }, output.health.fetch(:counts))
        assert_true output.health.dig(:appender, :active)
      ensure
        output&.close
      end

      private

      def wait_for_async_appender(output)
        Timeout.timeout(SemanticLoggerTransportFixtures::ASYNC_TEST_TIMEOUT) do
          Thread.pass until output.health.dig(:appender, :active) && output.health.dig(:appender, :queue_size).zero?
        end
      end
    end

    class TestSemanticLoggerTransportConcurrency < Minitest::Test
      cover "Julewire::SemanticLogger::Transport#write"
      def test_sync_transport_serializes_appender_log_calls
        appender = SemanticLoggerTransportFixtures::BlockingAppender.new
        output = Transport.new(appender: appender, async: false)

        first = safe_thread { output.write({ message: "first" }, severity: :info) }
        appender.wait_for_entry
        second = start_blocked_write(output, "second")

        assert_false appender.concurrent
        refute_predicate appender, :entry_pending?

        appender.release
        appender.wait_for_entry
        appender.release
        safe_thread_values([first, second])

        assert_false appender.concurrent
      ensure
        2.times { appender&.release }
        [first, second].compact.each { cleanup_thread(it) }
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
        thread = safe_thread do
          started << true
          output.write({ message: message }, severity: :info)
        end
        safe_queue_pop(started)
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
      cover "Julewire::SemanticLogger::Transport#write"
      cover Julewire::SemanticLogger::Destination
      LineFormatter = SemanticLoggerTransportFixtures::LineFormatter
      FailingIO = SemanticLoggerTransportFixtures::FailingIO

      def test_transport_counts_and_reraises_write_failures
        output = Transport.new(io: FailingIO.new, async: false)

        error = assert_raises(RuntimeError) do
          output.write({ severity: :info, message: "fail" }, severity: :info)
        end

        assert_equal "write failed", error.message
        assert_equal :degraded, output.health.fetch(:status)
        assert_equal({ writes: 1, failures: 1 }, output.health.fetch(:counts))
        assert_equal "RuntimeError", output.health.dig(:last_failure, :class)
      ensure
        output&.close
      end

      def test_transport_flush_clears_degraded_state
        output = Transport.new(io: FailingIO.new, async: false)

        assert_raises(RuntimeError) do
          output.write({ severity: :info, message: "fail" }, severity: :info)
        end
        assert_equal :degraded, output.health.fetch(:status)

        output.flush

        health = output.health

        assert_equal :ok, health.fetch(:status)
        assert_equal "RuntimeError", health.dig(:last_failure, :class)
      ensure
        output&.close
      end

      def test_transport_degraded_status_recovers_after_successful_write
        output = Transport.new(io: SemanticLoggerTransportFixtures::FlakyIO.new, async: false)

        assert_raises(RuntimeError) do
          output.write({ message: "fail" }, severity: :info)
        end
        assert_equal :degraded, output.health.fetch(:status)

        output.write({ message: "recover" }, severity: :info)

        health = output.health

        assert_equal :ok, health.fetch(:status)
        assert_equal({ writes: 2, failures: 1 }, health.fetch(:counts))
        assert_equal "RuntimeError", health.dig(:last_failure, :class)
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

    class TestSemanticLoggerAppenderHealth < Minitest::Test
      cover Julewire::SemanticLogger::AppenderHealth
      cover "Julewire::SemanticLogger::AppenderHealth.file_health"
      cover "Julewire::SemanticLogger::AppenderHealth.async_health"
      cover "Julewire::SemanticLogger::AppenderHealth.collection_health"
      def test_reports_generic_appender_class_index_and_type
        appender = Object.new

        assert_equal(
          { appender_class: "Object", index: 7, type: "appender" },
          AppenderHealth.call(appender, index: 7)
        )
      end

      def test_omits_nil_index
        health = AppenderHealth.call(Object.new)

        refute_includes health, :index
      end

      def test_reports_subclassed_semantic_logger_appenders
        io_class = Class.new(::SemanticLogger::Appender::IO)
        async_class = Class.new(::SemanticLogger::Appender::Async)
        collection_class = Class.new(::SemanticLogger::Appenders)

        assert_equal "io", AppenderHealth.call(io_class.new(StringIO.new, formatter: ExactFormatter.new)).fetch(:type)

        wrapped = ::SemanticLogger::Appender::IO.new(StringIO.new, formatter: ExactFormatter.new)
        async = async_class.new(appender: wrapped, max_queue_size: 2)
        async_health = AppenderHealth.call(async)

        assert_equal "async", async_health.fetch(:type)
        assert_true async_health.fetch(:active)
        assert_true async_health.fetch(:capped)
        assert_equal 0, async_health.fetch(:queue_size)
        assert_equal "io", async_health.dig(:wrapped, :type)

        async.close

        assert_nil AppenderHealth.call(async).fetch(:active)

        collection = collection_class.new
        collection << wrapped

        assert_equal "multi_appender", AppenderHealth.call(collection).fetch(:type)
        assert_equal(["io"], AppenderHealth.call(collection).fetch(:appenders).map { it.fetch(:type) })

        Dir.mktmpdir do |dir|
          file_class = Class.new(::SemanticLogger::Appender::File)
          file = file_class.new(File.join(dir, "subclass.log"), formatter: ExactFormatter.new)

          health = AppenderHealth.call(file)

          assert_equal "file", health.fetch(:type)
          assert_equal File.join(dir, "subclass.log"), health.fetch(:file_name)
        ensure
          file&.close
        end
      end
    end

    class TestSemanticLoggerLifecycleWarnings < Minitest::Test
      cover Julewire::SemanticLogger::LifecycleWarnings
      def test_reports_async_blocking_queue_with_capacity
        assert_equal(
          [{ reason: :async_queue_blocks_when_full, max_queue_size: 8 }],
          LifecycleWarnings.call(async: true, appender_count: 1, max_queue_size: 8)
        )
      end

      def test_reports_unbounded_queue_only_for_async_transport
        assert_equal(
          [{ reason: :async_queue_unbounded }],
          LifecycleWarnings.call(async: true, appender_count: 1, max_queue_size: -1)
        )
        assert_empty LifecycleWarnings.call(async: false, appender_count: 1, max_queue_size: -1)
      end

      def test_reports_sync_multi_appender
        assert_equal(
          [{ reason: :sync_multi_appender_blocks_emitters, appender_count: 2 }],
          LifecycleWarnings.call(async: false, appender_count: 2, max_queue_size: 10)
        )
      end
    end
  end
end
