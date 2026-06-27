# frozen_string_literal: true

require "test_helper"
require "json"
require "stringio"

module Julewire
  class TestRuntimeLifecycleAndConcurrency < Minitest::Test
    cover "Julewire::Core::Runtime#build_configured_pipeline"
    cover "Julewire::Core::Runtime#close_state"
    cover "Julewire::Core::Runtime#configure"
    cover "Julewire::Core::Runtime#install_and_replace_pipeline"
    cover "Julewire::Core::Runtime#replace_pipeline"
    cover "Julewire::Core::Runtime#report_pipeline_close_result"
    cover "Julewire::Core::Runtime#reset!"
    cover Julewire::Core::Destinations::SynchronizedOutput
    class CapturingOutput
      attr_reader :values

      def initialize
        @values = []
        @flushed = Queue.new
      end

      def write(value)
        @values << value
      end

      def flush
        @flushed << true
      end

      def flushed?
        @flushed.pop(true)
      rescue ThreadError
        false
      end
    end

    class TimeoutRecordingOutput < Julewire::Core::Destinations::SynchronizedOutput
      attr_reader :close_count, :close_timeout

      def initialize(close_result: true)
        super(StringIO.new)
        @close_count = 0
        @close_result = close_result
      end

      def close(timeout: nil)
        @close_count += 1
        @close_timeout = timeout
        @close_result
      end
    end

    class CloseTrackingOutput
      attr_reader :close_count, :values

      def initialize
        @close_count = 0
        @values = []
      end

      def write(value)
        raise "closed output wrote" if closed?

        @values << value
      end

      def close
        @close_count += 1
      end

      def closed?
        @close_count.positive?
      end
    end

    class ReusedCustomDestination
      attr_reader :close_count, :emitted

      def initialize
        @close_count = 0
        @emitted = 0
      end

      def name = :custom

      def emit(_record)
        raise "closed destination emitted" if closed?

        @emitted += 1
      end

      def flush(*) = :flushed

      def close(*)
        @close_count += 1
        :closed
      end

      def health = { status: closed? ? :closed : :ok, counts: { emitted: @emitted } }

      private

      def closed?
        @close_count.positive?
      end
    end

    class OverlapDetectingOutput
      attr_reader :values

      def initialize
        @guard = Mutex.new
        @overlap = false
        @values = []
      end

      def write(value)
        locked = @guard.try_lock
        unless locked
          @overlap = true
          @guard.lock
          locked = true
        end

        sleep 0.001
        values << value
      ensure
        @guard.unlock if locked
      end

      def overlap?
        @overlap
      end
    end

    class InstallProbeOutput
      attr_reader :close_timeouts

      def initialize
        @close_timeouts = []
      end

      def write(_value) = true # rubocop:disable Naming/PredicateMethod
      def flush(timeout: nil) = timeout || true

      def close(timeout: nil, **) # rubocop:disable Naming/PredicateMethod
        @close_timeouts << timeout
        true
      end
    end

    def test_configure_rejects_a_state_made_stale_by_close_and_closes_its_new_pipeline
      runtime = Julewire::Core::Runtime.new
      output = InstallProbeOutput.new
      ready = Queue.new
      continue = Queue.new
      configure_thread = safe_thread do
        runtime.configure do |config|
          configure_destination(config, output: output, close_output: true)
          config.pipeline_close_timeout = 0.25
          ready << true
          continue.pop
        end
      rescue StandardError => e
        e
      end

      safe_queue_pop(ready)

      assert_true runtime.close(timeout: 0)
      continue << true
      error = safe_thread_value(configure_thread)

      assert_instance_of Julewire::Core::Error, error
      assert_equal "Julewire.configure state changed before install completed", error.message
      assert_in_delta 0.25, output.close_timeouts.fetch(0), 0.01
    ensure
      continue << true if defined?(continue)
      cleanup_thread(configure_thread) if defined?(configure_thread)
    end

    def test_configure_transactions_do_not_overlap
      runtime = Julewire::Core::Runtime.new
      first_entered = Queue.new
      release_first = Queue.new
      first_thread = safe_thread do
        runtime.configure do |config|
          configure_destination(config, output: StringIO.new)
          first_entered << true
          release_first.pop
        end
      rescue StandardError => e
        e
      end
      safe_queue_pop(first_entered)
      second_thread = safe_thread do
        runtime.configure { configure_destination(it, output: StringIO.new) }
      rescue StandardError => e
        e
      end

      refute second_thread.join(0.05), "concurrent configure transactions overlapped"
      release_first << true

      first_result = safe_thread_value(first_thread)
      second_result = safe_thread_value(second_thread)

      refute_kind_of Exception, first_result
      refute_kind_of Exception, second_result
      assert_instance_of Julewire::Core::Configuration, first_result
      assert_instance_of Julewire::Core::Configuration, second_result
    ensure
      release_first << true if defined?(release_first)
      cleanup_thread(first_thread) if defined?(first_thread)
      cleanup_thread(second_thread) if defined?(second_thread)
    end

    def test_reset_waits_for_an_active_configure_transaction
      runtime = Julewire::Core::Runtime.new
      configure_entered = Queue.new
      release_configure = Queue.new
      configure_thread = safe_thread do
        runtime.configure do |config|
          configure_destination(config, output: StringIO.new)
          configure_entered << true
          release_configure.pop
        end
      rescue StandardError => e
        e
      end
      safe_queue_pop(configure_entered)
      reset_thread = safe_thread { runtime.reset! }

      refute reset_thread.join(0.05), "reset completed during a configure transaction"
      release_configure << true
      configure_result = safe_thread_value(configure_thread)
      reset_result = safe_thread_value(reset_thread)

      refute_kind_of Exception, configure_result
      refute_kind_of Exception, reset_result
      assert_empty runtime.config.destinations
    ensure
      release_configure << true if defined?(release_configure)
      cleanup_thread(configure_thread) if defined?(configure_thread)
      cleanup_thread(reset_thread) if defined?(reset_thread)
    end

    def test_reconfigure_flushes_previous_caller_owned_output
      old_target = CapturingOutput.new
      new_target = CapturingOutput.new

      Julewire.configure do |config|
        configure_destination(config, output: old_target)
      end

      Julewire.configure do |config|
        configure_destination(config, output: new_target)
      end

      assert_predicate old_target, :flushed?
    end

    def test_reconfigure_closes_previous_pipeline_with_previous_deadline
      old_output = TimeoutRecordingOutput.new(close_result: false)
      failures = Queue.new

      Julewire.configure do |config|
        configure_destination(config, output: old_output)
        config.on_failure = ->(error, metadata) { failures << [error, metadata] }
        config.pipeline_close_timeout = 0.25
      end

      Julewire.configure do |config|
        configure_destination(config, output: StringIO.new)
        config.pipeline_close_timeout = 0.01
      end

      assert_equal 1, old_output.close_count
      assert_operator old_output.close_timeout, :>, 0.2
      assert_operator old_output.close_timeout, :<=, 0.25
      error, metadata = safe_queue_pop(failures)

      assert_instance_of Julewire::Core::LifecycleError, error
      assert_equal :configure, metadata.fetch(:operation)
      assert_equal :close, metadata.fetch(:action)
    end

    def test_reconfigure_does_not_close_reused_owned_output
      output = CloseTrackingOutput.new

      Julewire.configure do |config|
        configure_destination(config, output: output, close_output: true)
      end

      Julewire.configure do |config|
        config.level = :warn
      end

      refute_predicate output, :closed?

      Julewire.emit(severity: :warn, message: "after reconfigure")
      Julewire.close

      assert_equal 1, output.values.length
      assert_equal 1, output.close_count
    end

    def test_reconfigure_does_not_close_reused_custom_destination
      destination = ReusedCustomDestination.new

      Julewire.configure do |config|
        config.destinations.clear
        config.destinations.add(destination)
      end

      Julewire.configure do |config|
        config.level = :warn
      end

      assert_equal 0, destination.close_count

      Julewire.emit(severity: :warn, message: "after reconfigure")
      Julewire.close

      assert_equal 1, destination.emitted
      assert_equal 1, destination.close_count
    end

    def test_reset_flushes_previous_caller_owned_output
      target = CapturingOutput.new

      Julewire.configure do |config|
        configure_destination(config, output: target)
      end

      Julewire.reset!

      assert_predicate target, :flushed?
    end

    def test_concurrent_emit_serializes_writes_to_plain_output
      output = OverlapDetectingOutput.new

      Julewire.configure { configure_destination(it, output: output) }

      threads = Array.new(20) do |index|
        safe_thread { Julewire.emit(message: "message-#{index}") }
      end
      safe_thread_values(threads)

      assert_equal 20, output.values.length
      refute_predicate output, :overlap?
    end

    def test_top_level_close_is_idempotent_for_sync_output
      target = CapturingOutput.new

      Julewire.configure do |config|
        configure_destination(config, output: target)
      end
      Julewire.emit(message: "closing")

      assert_true Julewire.close(timeout: 1)
      assert_true Julewire.close(timeout: 0.01)
      assert_true Julewire.flush(timeout: 0.01)
    end
  end
end
