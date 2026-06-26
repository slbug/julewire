# frozen_string_literal: true

require "test_helper"
require "stringio"

module Julewire
  class TestOutputLifecycle < Minitest::Test
    cover Julewire::Core::Destinations::ChaosOutput

    class FlushableOutput
      attr_reader :flush_count, :value

      def initialize
        @flush_count = 0
      end

      def write(value)
        @value = value
      end

      def flush
        @flush_count += 1
      end
    end

    class CloseableOutput < FlushableOutput
      attr_reader :close_count

      def initialize
        super
        @close_count = 0
      end

      def close
        @close_count += 1
      end
    end

    class TimeoutAwareOutput
      attr_reader :close_timeout, :flush_timeout

      def write(_value); end

      def flush(timeout: nil)
        @flush_timeout = timeout
      end

      def close(timeout: nil)
        @close_timeout = timeout
      end
    end

    class FailingLifecycleOutput
      def write(_value); end

      def flush
        raise "flush failed"
      end

      def close
        raise "close failed"
      end
    end

    class FalseReturningOutput
      attr_reader :value

      def write(value) # rubocop:disable Naming/PredicateMethod
        @value = value
        false
      end
    end

    class FalseLifecycleOutput
      attr_reader :calls

      def initialize
        @calls = []
        @lifecycle_result = false
      end

      def write(_value); end

      def flush
        @calls << :flush
        @lifecycle_result
      end

      def close
        @calls << :close
        @lifecycle_result
      end
    end

    class WriteOnlyOutput
      def write(_value); end
    end

    class BlockingWriteOutput
      WAIT_TIMEOUT = 1

      attr_reader :flush_count, :write_started

      def initialize
        @flush_count = 0
        @write_started = Queue.new
        @flush_started = Queue.new
        @release_write = Queue.new
      end

      def write(_value)
        @write_started << true
        @release_write.pop
      end

      def flush
        @flush_count += 1
        @flush_started << true
      end

      def release_write = @release_write << true

      def wait_for_flush = @flush_started.pop(timeout: WAIT_TIMEOUT)
    end

    class ForkAwareOutput < WriteOnlyOutput
      attr_reader :after_fork_count

      def after_fork!
        @after_fork_count = after_fork_count.to_i + 1
      end
    end

    class LifecycleProbeOutput < ForkAwareOutput
      attr_reader :close_count, :flush_count, :values

      def initialize
        super
        @close_count = 0
        @flush_count = 0
        @values = []
        @closed = false
      end

      def write(value)
        values << value
        value.bytesize
      end

      def flush
        @flush_count += 1
      end

      def close
        @close_count += 1
        @closed = true
      end

      def closed? = @closed
    end

    def test_deadline_remaining_returns_zero_after_deadline_expires
      past_deadline = Process.clock_gettime(Julewire::Core::Scheduling::Deadline::CLOCK) - 1

      assert_equal 0, Julewire::Core::Scheduling::Deadline.remaining(past_deadline)
    end

    def test_pipeline_flushes_explicitly
      output = FlushableOutput.new
      pipeline = build_pipeline(output: output)

      pipeline.emit(message: "hello")

      assert_equal 0, output.flush_count
      assert pipeline.flush
      assert_equal 1, output.flush_count
    end

    def test_pipeline_forwards_lifecycle_timeout_to_timeout_aware_output
      output = TimeoutAwareOutput.new
      pipeline = build_pipeline(output: output)

      assert pipeline.flush(timeout: 0.25)

      assert_in_delta 0.25, output.flush_timeout, 0.01
    end

    def test_synchronized_output_forwards_close_timeout_to_timeout_aware_owned_output
      output = TimeoutAwareOutput.new
      synchronized = Julewire::Core::Destinations::SynchronizedOutput.new(output, close_output: true)

      assert synchronized.close(timeout: 0.5)

      assert_in_delta 0.5, output.close_timeout
    end

    def test_synchronized_output_lifecycle_does_not_wait_for_write_mutex
      raw_output = BlockingWriteOutput.new
      output = Julewire::Core::Destinations::SynchronizedOutput.new(raw_output)
      writer = Thread.new { output.write("held") }

      assert raw_output.write_started.pop(timeout: TEST_THREAD_TIMEOUT)
      flusher = Thread.new { output.flush }

      assert raw_output.wait_for_flush
      assert_equal 1, raw_output.flush_count
    ensure
      raw_output&.release_write
      writer&.join(TEST_THREAD_TIMEOUT)
      flusher&.join(TEST_THREAD_TIMEOUT)
    end

    def test_pipeline_close_flushes_caller_owned_output
      output = CloseableOutput.new
      pipeline = build_pipeline(output: output)

      assert pipeline.close

      assert_equal 1, output.flush_count
      assert_equal 0, output.close_count
    end

    def test_synchronized_output_can_close_owned_output
      raw_output = CloseableOutput.new
      output = Julewire::Core::Destinations::SynchronizedOutput.new(raw_output, close_output: true)

      output.close

      assert_equal 1, raw_output.close_count
    end

    def test_synchronized_output_forwards_after_fork
      raw_output = ForkAwareOutput.new
      output = Julewire::Core::Destinations::SynchronizedOutput.new(raw_output)

      assert_same output, output.after_fork!
      assert_equal 1, raw_output.after_fork_count
    end

    def test_config_close_output_controls_output_ownership
      caller_owned = CloseableOutput.new
      julewire_owned = CloseableOutput.new

      Julewire.configure { configure_destination(it, output: caller_owned) }
      Julewire.configure do |config|
        configure_destination(config, output: julewire_owned, close_output: true)
      end
      Julewire.close

      assert_equal [1, 0], [caller_owned.flush_count, caller_owned.close_count]
      assert_equal [0, 1], [julewire_owned.flush_count, julewire_owned.close_count]
    end

    def test_pipeline_counts_false_write_as_rejected_output
      raw_output = FalseReturningOutput.new
      pipeline = build_pipeline(output: raw_output)

      result = pipeline.emit(message: "hello")
      counts = pipeline.health.dig(:destinations, :default, :counts)

      assert_nil result
      assert_includes raw_output.value, "hello"
      assert_equal 0, counts.fetch(:output_accepted)
      assert_equal 1, counts.fetch(:output_rejected)
      assert_equal 1, counts.fetch(:output_error)
    end

    def test_synchronized_output_preserves_false_lifecycle_results
      raw_output = FalseLifecycleOutput.new
      output = Julewire::Core::Destinations::SynchronizedOutput.new(raw_output, close_output: true)

      refute output.flush
      refute output.close
      assert_equal %i[flush close], raw_output.calls
    end

    def test_chaos_output_modes_and_lifecycle
      raw_output = LifecycleProbeOutput.new
      pass_through = Julewire::Core::Destinations::ChaosOutput.new(raw_output, rate: 0)
      reject = Julewire::Core::Destinations::ChaosOutput.new(raw_output, rate: 1, mode: :reject, seed: 1)
      sleep_output = Julewire::Core::Destinations::ChaosOutput.new(
        raw_output, rate: 1, mode: :sleep, sleep_ms: 0, seed: 1
      )

      assert_equal 2, pass_through.write("ok")
      assert_same false, reject.write("drop")
      assert_equal 5, sleep_output.write("sleep")
      assert_equal 1, pass_through.flush
      assert pass_through.close
      assert_predicate raw_output, :closed?
      assert_predicate pass_through, :closed?
      assert_equal 1, raw_output.flush_count
      assert_equal 1, raw_output.close_count
      assert_same pass_through, pass_through.after_fork!
      assert_equal 1, raw_output.after_fork_count
    end

    def test_chaos_output_mixed_mode_can_reject_and_sleep
      raw_output = LifecycleProbeOutput.new
      mixed_reject = Julewire::Core::Destinations::ChaosOutput.new(raw_output, rate: 1, seed: 0)
      mixed_sleep = Julewire::Core::Destinations::ChaosOutput.new(raw_output, rate: 1, sleep_ms: 0, seed: 9)

      assert_same false, mixed_reject.write("drop")
      assert_equal 5, mixed_sleep.write("sleep")
      assert_equal ["sleep"], raw_output.values
    end

    def test_chaos_output_raises_and_resets_seed_after_fork
      raw_output = LifecycleProbeOutput.new
      output = Julewire::Core::Destinations::ChaosOutput.new(raw_output, rate: 1, mode: :mixed, seed: 1)

      error = assert_raises(RuntimeError) { output.write("first") }
      assert_equal "julewire punk chaos output failure", error.message
      assert_same output, output.after_fork!
      assert_raises(RuntimeError) { output.write("second") }
      assert_empty raw_output.values
    end

    def test_chaos_output_delegates_identity_and_handles_write_only_lifecycle
      raw_output = WriteOnlyOutput.new
      output = Julewire::Core::Destinations::ChaosOutput.new(raw_output, rate: 0)

      assert_same raw_output, output.resource_identity
      assert_nil output.flush
      assert_nil output.close
      assert_nil output.closed?
      assert_same output, output.after_fork!

      lifecycle_output = LifecycleProbeOutput.new
      lifecycle = Julewire::Core::Destinations::ChaosOutput.new(lifecycle_output, rate: 0)

      refute_predicate lifecycle, :closed?
      lifecycle.close

      assert_predicate lifecycle, :closed?
    end

    def test_chaos_output_validates_output_rate_and_mode
      raw_output = WriteOnlyOutput.new

      assert_raises(ArgumentError) { Julewire::Core::Destinations::ChaosOutput.new(Object.new) }
      assert_kind_of Julewire::Core::Destinations::ChaosOutput, Julewire::Core::Destinations::ChaosOutput.new(raw_output)

      rate_error = assert_raises(ArgumentError) { Julewire::Core::Destinations::ChaosOutput.new(raw_output, rate: "nope") }
      assert_equal "chaos rate must be a finite Numeric between 0 and 1", rate_error.message
      assert_raises(ArgumentError) { Julewire::Core::Destinations::ChaosOutput.new(raw_output, rate: -0.1) }
      assert_raises(ArgumentError) { Julewire::Core::Destinations::ChaosOutput.new(raw_output, rate: 2) }
      assert_raises(ArgumentError) { Julewire::Core::Destinations::ChaosOutput.new(raw_output, rate: Float::INFINITY) }
      assert_raises(ArgumentError) { Julewire::Core::Destinations::ChaosOutput.new(raw_output, rate: Float::NAN) }
      assert_raises(ArgumentError) { Julewire::Core::Destinations::ChaosOutput.new(raw_output, rate: Complex(1, 0)) }

      mode_error = assert_raises(ArgumentError) { Julewire::Core::Destinations::ChaosOutput.new(raw_output, mode: :quiet) }
      assert_equal "chaos mode must be one of: mixed, raise, reject, sleep", mode_error.message
    end

    def test_chaos_output_validates_sleep_ms
      raw_output = WriteOnlyOutput.new

      sleep_error = assert_raises(ArgumentError) { Julewire::Core::Destinations::ChaosOutput.new(raw_output, sleep_ms: "nope") }
      assert_equal "chaos sleep_ms must be a non-negative finite Numeric", sleep_error.message
      assert_raises(ArgumentError) { Julewire::Core::Destinations::ChaosOutput.new(raw_output, sleep_ms: -1) }
      assert_raises(ArgumentError) { Julewire::Core::Destinations::ChaosOutput.new(raw_output, sleep_ms: Float::INFINITY) }
      assert_raises(ArgumentError) { Julewire::Core::Destinations::ChaosOutput.new(raw_output, sleep_ms: Float::NAN) }
      assert_raises(ArgumentError) { Julewire::Core::Destinations::ChaosOutput.new(raw_output, sleep_ms: Complex(1, 0)) }
    end

    def test_pipeline_lifecycle_is_successful_without_output
      pipeline = build_pipeline(output: nil)

      assert pipeline.flush
      assert pipeline.close
    end

    def test_pipeline_lifecycle_rejects_invalid_timeouts
      pipeline = build_pipeline(output: nil)

      assert_raises(ArgumentError) { pipeline.flush(timeout: -1) }
      assert_raises(ArgumentError) { pipeline.close(timeout: "slow") }
    end

    def test_pipeline_emit_is_noop_without_output
      formatter = Class.new do
        def call(_record)
          raise "formatter should not run"
        end
      end.new
      pipeline = build_pipeline(formatter: formatter, output: nil)

      assert_nil pipeline.emit(message: "ignored")
    end

    def test_pipeline_lifecycle_returns_false_when_output_raises
      pipeline = build_pipeline(output: FailingLifecycleOutput.new)

      refute pipeline.flush
      refute pipeline.close
    end

    def test_pipeline_lifecycle_failures_report_action_metadata
      failures = Queue.new
      pipeline = build_pipeline(
        on_failure: ->(error, metadata) { failures << [error, metadata] },
        output: FailingLifecycleOutput.new
      )

      refute pipeline.flush

      error, metadata = failures.pop(true)
      health = pipeline.health.dig(:destinations, :default)

      assert_equal "flush failed", error.message
      assert_equal :flush, metadata.fetch(:action)
      assert_equal :output_lifecycle, metadata.fetch(:phase)
      assert_equal 1, health.dig(:counts, :failures)
    end

    def test_configuration_rejects_output_arrays
      error = assert_raises(ArgumentError) do
        Julewire.configure { configure_destination(it, output: [StringIO.new]) }
      end

      assert_equal "output arrays are transport adapter behavior; use destinations or an adapter output", error.message
    end

    def test_lifecycle_methods_return_true_for_noop_outputs
      output = Julewire::Core::Destinations::SynchronizedOutput.new(WriteOnlyOutput.new)

      assert output.flush
      assert output.close
    end
  end
end
