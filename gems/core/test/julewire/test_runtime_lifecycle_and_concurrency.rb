# frozen_string_literal: true

require "test_helper"
require "json"
require "stringio"

module Julewire
  class TestRuntimeLifecycleAndConcurrency < Minitest::Test
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

    class BlockingOutput
      def initialize(write_started: Queue.new, release: Queue.new)
        @write_started = write_started
        @release = release
      end

      def write(_value)
        @write_started << true
        @release.pop
      end

      def wait_for_write
        @write_started.pop
      end

      def release
        @release << :continue
      end
    end

    class TimeoutRecordingOutput < Julewire::Core::Destinations::SynchronizedOutput
      attr_reader :close_count, :close_timeout

      def initialize
        super(StringIO.new)
        @close_count = 0
      end

      def close(timeout: nil)
        @close_count += 1
        @close_timeout = timeout
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
      old_output = TimeoutRecordingOutput.new

      Julewire.configure do |config|
        configure_destination(config, output: old_output)
        config.pipeline_close_timeout = 0.25
      end

      Julewire.configure do |config|
        configure_destination(config, output: StringIO.new)
        config.pipeline_close_timeout = 0.01
      end

      assert_equal 1, old_output.close_count
      assert_in_delta 0.25, old_output.close_timeout
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
        Thread.new { Julewire.emit(message: "message-#{index}") }
      end
      threads.each(&:value)

      assert_equal 20, output.values.length
      refute_predicate output, :overlap?
    end

    def test_top_level_close_is_idempotent_for_sync_output
      target = CapturingOutput.new

      Julewire.configure do |config|
        configure_destination(config, output: target)
      end
      Julewire.emit(message: "closing")

      assert Julewire.close(timeout: 1)
      assert Julewire.close(timeout: 0.01)
      assert Julewire.flush(timeout: 0.01)
    end
  end
end
