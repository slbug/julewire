# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestSynchronizedOutputConcurrency < Minitest::Test
    cover Julewire::Core::Destinations::SynchronizedOutput
    class BlockingCloseOutput
      WAIT_TIMEOUT = 1

      attr_reader :write_count

      def initialize
        @closed = false
        @write_count = 0
        @close_started = Queue.new
        @release_close = Queue.new
      end

      def write(_value)
        @write_count += 1
      end

      def close
        @close_started << true
        @release_close.pop
        @closed = true
      end

      def closed? = @closed

      def release_close = @release_close << true

      def wait_for_close = @close_started.pop(timeout: WAIT_TIMEOUT)
    end

    class KeyrestLifecycleOutput
      attr_reader :close_kwargs, :flush_kwargs

      def write(_value); end

      def flush(**kwargs)
        @flush_kwargs = kwargs
      end

      def close(**kwargs)
        @close_kwargs = kwargs
      end
    end

    class OtherKeywordLifecycleOutput
      attr_reader :close_extra, :flush_extra

      def write(_value); end

      def flush(extra: nil)
        @flush_extra = extra
      end

      def close(extra: nil)
        @close_extra = extra
      end
    end

    class RestLifecycleOutput
      attr_reader :close_args, :flush_args

      def write(_value); end

      def flush(*args)
        @flush_args = args
      end

      def close(*args)
        @close_args = args
      end
    end

    class PositionalTimeoutLifecycleOutput
      attr_reader :close_value, :flush_value

      def write(_value); end

      def flush(timeout = :default)
        @flush_value = timeout
      end

      def close(timeout = :default)
        @close_value = timeout
      end
    end

    class BlockingFlushCloseOutput
      WAIT_TIMEOUT = 1

      attr_reader :events

      def initialize
        @events = Queue.new
        @flush_started = Queue.new
        @close_started = Queue.new
        @release_flush = Queue.new
      end

      def write(_value); end

      def flush(timeout: nil)
        @events << [:flush, timeout]
        @flush_started << true
        @release_flush.pop
      end

      def close(timeout: nil)
        @events << [:close, timeout]
        @close_started << true
      end

      def close_started(timeout:) = @close_started.pop(timeout: timeout)

      def release_flush = @release_flush << true

      def wait_for_flush = @flush_started.pop(timeout: WAIT_TIMEOUT)
    end

    class FlushOnlyTimeoutOutput
      attr_reader :flush_count, :flush_timeout

      def write(_value); end

      def flush(timeout: nil)
        @flush_count = flush_count.to_i + 1
        @flush_timeout = timeout
      end
    end

    class TruthyLifecycleOutput
      def write(_value); end

      def flush = :flushed

      def close = :closed
    end

    class ForkRefreshOutput
      attr_reader :after_fork_count, :flush_timeout, :writes

      def initialize
        @after_fork_count = 0
        @forked = false
        @writes = []
      end

      def write(value)
        @writes << value
      end

      def after_fork!
        @after_fork_count += 1
        @forked = true
      end

      def flush(timeout: nil)
        @flush_timeout = timeout
      end

      # Mirror Ruby's respond_to? positional private-visibility flag.
      def respond_to?(name, include_private = false) # rubocop:disable Style/OptionalBooleanParameter
        return @forked if name == :flush

        super
      end
    end

    def test_write_started_during_terminal_close_is_rejected_after_close
      raw_output = BlockingCloseOutput.new
      output = Julewire::Core::Destinations::SynchronizedOutput.new(raw_output, close_output: true)
      closer = safe_thread { output.close }

      assert raw_output.wait_for_close

      writer_ready = Queue.new
      writer_result = Queue.new
      writer = safe_thread do
        writer_ready << true
        writer_result << output.write("late")
      end

      assert writer_ready.pop(timeout: 1)

      raw_output.release_close

      assert safe_thread_value(closer)
      assert_false writer_result.pop(timeout: 1)
      assert_equal 0, raw_output.write_count
    ensure
      raw_output&.release_close
      safe_thread_value(closer) if closer&.alive?
      safe_thread_value(writer) if writer&.alive?
    end

    def test_terminal_close_waits_for_in_flight_flush
      raw_output = BlockingFlushCloseOutput.new
      output = Julewire::Core::Destinations::SynchronizedOutput.new(raw_output, close_output: true)
      flusher = safe_thread { output.flush(timeout: 0.25) }

      assert raw_output.wait_for_flush

      closer = safe_thread { output.close(timeout: 0.5) }

      assert_nil raw_output.close_started(timeout: 0.1)

      raw_output.release_flush

      assert safe_thread_value(flusher)
      assert safe_thread_value(closer)
      assert_equal [[:flush, 0.25], [:close, 0.5]], nonblocking_queue_values(raw_output.events)
    ensure
      raw_output&.release_flush
      safe_thread_value(flusher) if flusher&.alive?
      safe_thread_value(closer) if closer&.alive?
    end

    def test_lifecycle_timeout_is_forwarded_to_keyrest_output_methods
      raw_output = KeyrestLifecycleOutput.new
      output = Julewire::Core::Destinations::SynchronizedOutput.new(raw_output, close_output: true)

      assert_true output.flush(timeout: 0.25)
      assert_equal({ timeout: 0.25 }, raw_output.flush_kwargs)

      assert_true output.close(timeout: 0.5)
      assert_equal({ timeout: 0.5 }, raw_output.close_kwargs)
    end

    def test_lifecycle_timeout_is_not_forwarded_to_other_keyword_methods
      raw_output = OtherKeywordLifecycleOutput.new
      output = Julewire::Core::Destinations::SynchronizedOutput.new(raw_output, close_output: true)

      assert_true output.flush(timeout: 0.25)
      assert_nil raw_output.flush_extra

      assert_true output.close(timeout: 0.5)
      assert_nil raw_output.close_extra
    end

    def test_lifecycle_timeout_is_not_forwarded_to_positional_rest_methods
      raw_output = RestLifecycleOutput.new
      output = Julewire::Core::Destinations::SynchronizedOutput.new(raw_output, close_output: true)

      assert_true output.flush(timeout: 0.25)
      assert_empty raw_output.flush_args

      assert_true output.close(timeout: 0.5)
      assert_empty raw_output.close_args
    end

    def test_lifecycle_timeout_is_not_forwarded_to_positional_timeout_methods
      raw_output = PositionalTimeoutLifecycleOutput.new
      output = Julewire::Core::Destinations::SynchronizedOutput.new(raw_output, close_output: true)

      assert_true output.flush(timeout: 0.25)
      assert_equal :default, raw_output.flush_value

      assert_true output.close(timeout: 0.5)
      assert_equal :default, raw_output.close_value
    end

    def test_close_falls_back_to_timeout_aware_flush_when_output_has_no_close
      raw_output = FlushOnlyTimeoutOutput.new
      output = Julewire::Core::Destinations::SynchronizedOutput.new(raw_output, close_output: true)

      assert_true output.close(timeout: 0.5)

      assert_equal 1, raw_output.flush_count
      assert_in_delta(0.5, raw_output.flush_timeout)
    end

    def test_close_normalizes_truthy_lifecycle_results
      close_output = Julewire::Core::Destinations::SynchronizedOutput.new(
        TruthyLifecycleOutput.new,
        close_output: true
      )
      flush_output = Julewire::Core::Destinations::SynchronizedOutput.new(TruthyLifecycleOutput.new)

      assert_true close_output.close
      assert_true flush_output.close
    end

    def test_after_fork_rebuilds_lifecycle_and_keeps_output_usable
      raw_output = ForkRefreshOutput.new
      output = Julewire::Core::Destinations::SynchronizedOutput.new(raw_output)
      plain_raw_output = FlushOnlyTimeoutOutput.new
      plain_output = Julewire::Core::Destinations::SynchronizedOutput.new(plain_raw_output)

      assert_same output, output.after_fork!
      output.write("after")

      assert_true output.flush(timeout: 0.25)
      assert_same plain_output, plain_output.after_fork!
      assert_true plain_output.flush(timeout: 0.5)

      assert_equal 1, raw_output.after_fork_count
      assert_equal ["after"], raw_output.writes
      assert_in_delta(0.25, raw_output.flush_timeout)
      assert_equal 1, plain_raw_output.flush_count
      assert_in_delta(0.5, plain_raw_output.flush_timeout)
    end
  end
end
