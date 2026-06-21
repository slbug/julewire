# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestSynchronizedOutputConcurrency < Minitest::Test
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

    def test_write_started_during_terminal_close_is_rejected_after_close
      raw_output = BlockingCloseOutput.new
      output = Julewire::Core::Destinations::SynchronizedOutput.new(raw_output, close_output: true)
      closer = Thread.new { output.close }

      assert raw_output.wait_for_close

      writer_ready = Queue.new
      writer_result = Queue.new
      writer = Thread.new do
        writer_ready << true
        writer_result << output.write("late")
      end

      assert writer_ready.pop(timeout: TEST_THREAD_TIMEOUT)

      raw_output.release_close

      assert closer.value
      assert_same false, writer_result.pop(timeout: TEST_THREAD_TIMEOUT)
      assert_equal 0, raw_output.write_count
    ensure
      raw_output&.release_close
      closer&.join(TEST_THREAD_TIMEOUT)
      writer&.join(TEST_THREAD_TIMEOUT)
    end

    def test_lifecycle_timeout_is_forwarded_to_keyrest_output_methods
      raw_output = KeyrestLifecycleOutput.new
      output = Julewire::Core::Destinations::SynchronizedOutput.new(raw_output, close_output: true)

      assert output.flush(timeout: 0.25)
      assert_equal({ timeout: 0.25 }, raw_output.flush_kwargs)

      assert output.close(timeout: 0.5)
      assert_equal({ timeout: 0.5 }, raw_output.close_kwargs)
    end
  end
end
