# frozen_string_literal: true

require "test_helper"
require "stringio"

module Julewire
  class TestRuntimeCallbackFailures < Minitest::Test
    cover "Julewire::Core::Runtime#build_runtime_health"
    cover "Julewire::Core::Runtime#clear_runtime_degradation_if_unchanged"
    cover "Julewire::Core::Runtime#emit_summary_record"
    cover "Julewire::Core::Runtime#health"
    cover "Julewire::Core::Runtime#notify_failure"
    cover "Julewire::Core::Runtime#record_post_close_emit"
    cover "Julewire::Core::Runtime#replace_pipeline"
    cover "Julewire::Core::Runtime#runtime_counts_snapshot"
    cover "Julewire::Core::Runtime#with_emit_guard"
    def test_summary_finalizer_callback_failures_are_counted
      runtime = failing_summary_runtime

      runtime.configure do |config|
        configure_destination(config, output: StringIO.new)
        config.on_failure = ->(_error, _metadata) { raise "callback failed" }
      end

      runtime.with_execution(type: :job) { :done }

      health = runtime.health

      assert_equal 1, health.dig(:counts, :runtime_callback_failures)
      assert_equal 1, health.dig(:counts, :runtime_failures)
      assert_equal :summary_emit, health.dig(:last_failure, :phase)
      assert_equal "RuntimeError", health.dig(:last_callback_failure, :class)
      assert_equal :summary_emit, health.dig(:last_callback_failure, :phase)
    end

    class SummaryScopeProbe
      def initialize(input, calls: nil)
        @input = input
        @calls = calls
      end

      def owned_summary_record_input
        @calls << :owned_summary_record_input if @calls
        @input
      end
    end

    def test_runtime_emit_rejects_calls_inside_configure
      old_config = Julewire.config

      assert_runtime_call_rejected_inside_configure(:emit) { Julewire.emit(message: "not during configure") }

      assert_same old_config, Julewire.config
    end

    def test_runtime_level_emit_failure_callback_failures_are_counted
      Julewire.configure do |config|
        config.on_failure = ->(_error, _metadata) { raise "callback failed" }
      end
      pipeline = active_pipeline
      previous_counts = Julewire.health.fetch(:counts)

      with_overridden_singleton_method(pipeline, :emit, proc { |_record, **| raise "escaped pipeline failure" }) do
        assert_nil Julewire.emit(message: "lost")
      end

      health = Julewire.health

      actual_delta = health.dig(:counts, :runtime_callback_failures) -
                     previous_counts.fetch(:runtime_callback_failures)
      runtime_failure_delta = health.dig(:counts, :runtime_failures) -
                              previous_counts.fetch(:runtime_failures)

      assert_equal 1, actual_delta
      assert_equal 1, runtime_failure_delta
    end

    def test_runtime_summary_emit_rejects_calls_inside_configure
      runtime = Julewire::Core::RuntimeLocator.current

      assert_runtime_call_rejected_inside_configure(:emit_summary_record) do
        runtime.emit_summary_record(SummaryScopeProbe.new(:unused))
      end
    end

    def test_runtime_summary_emit_after_close_uses_runtime_drop_path
      drops = Queue.new
      scope_calls = Queue.new
      Julewire.configure do |config|
        configure_destination(config, output: StringIO.new)
        config.on_drop = ->(reason, metadata) { drops << [reason, metadata] }
      end
      runtime = Julewire::Core::RuntimeLocator.current
      previous_counts = Julewire.health.fetch(:counts)

      runtime.close(timeout: 1)

      assert_nil runtime.emit_summary_record(SummaryScopeProbe.new(:unused, calls: scope_calls))

      health = Julewire.health
      reason, metadata = drops.pop(true)

      assert_empty nonblocking_queue_values(scope_calls)
      assert_equal :runtime_closed, reason
      assert_equal({ phase: :runtime, reason: :runtime_closed }, metadata)
      assert_equal 1, health.dig(:counts, :post_close_emits)
      assert_equal 1, health.dig(:counts, :post_close_emits_total) -
                      previous_counts.fetch(:post_close_emits_total)
    end

    def test_runtime_summary_emit_failures_notify_failure_callback
      failures = Queue.new
      configure_runtime_failure_capture(failures)
      previous_runtime_failures = Julewire.health.dig(:counts, :runtime_failures)
      pipeline = active_pipeline
      scope = SummaryScopeProbe.new(:summary_input)
      inputs = Queue.new

      with_overridden_singleton_method(pipeline, :emit_isolated_input, proc { |input|
        inputs << input
        raise "escaped summary pipeline failure"
      }) do
        assert_nil Julewire::Core::RuntimeLocator.current.emit_summary_record(scope)
      end

      failure = failures.pop(true)

      assert_equal :summary_input, inputs.pop(true)
      assert_equal "escaped summary pipeline failure", failure.message
      assert_runtime_failure_recorded(previous_runtime_failures)
      assert_equal :emit_summary_record, Julewire.health.dig(:last_failure, :action)
    end

    def test_runtime_summary_emit_rejects_string_keys_in_owned_input
      failures = Queue.new
      configure_runtime_failure_capture(failures)
      runtime = Julewire::Core::RuntimeLocator.current

      assert_nil runtime.emit_summary_record(SummaryScopeProbe.new({ payload: { "invalid" => true } }))

      failure = failures.pop(true)

      assert_instance_of TypeError, failure
      assert_equal Julewire::Core::Fields::Internal::RECORD_STRING_KEY_ERROR, failure.message
      assert_equal :emit_summary_record, Julewire.health.dig(:last_failure, :action)
    end

    def test_successful_emit_clears_unchanged_runtime_degradation
      failures = Queue.new
      configure_runtime_failure_capture(failures)
      pipeline = active_pipeline

      with_overridden_singleton_method(pipeline, :emit, proc { |*| raise "temporary pipeline failure" }) do
        assert_nil Julewire.emit(message: "lost")
      end

      assert_equal "temporary pipeline failure", failures.pop(true).message
      assert_equal :degraded, Julewire.health.fetch(:status)
      assert_equal :emit, Julewire.health.dig(:last_failure, :action)

      assert_runtime_status_recovers_after_successful_emit
    end

    def test_runtime_level_emit_failures_use_callback_from_emit_state
      original_failures = Queue.new
      replacement_failures = Queue.new
      Julewire.configure do |config|
        config.on_failure = ->(error, _metadata) { original_failures << error }
      end
      pipeline = active_pipeline

      with_overridden_singleton_method(
        pipeline,
        :emit,
        proc do |_record, **|
          Julewire.configure do |config|
            config.on_failure = ->(error, _metadata) { replacement_failures << error }
          end
          raise "snapshot pipeline failure"
        end
      ) do
        assert_nil Julewire.emit(message: "lost")
      end

      assert_equal "snapshot pipeline failure", original_failures.pop(true).message
      assert_empty nonblocking_queue_values(replacement_failures)
    end

    private

    def active_pipeline
      Julewire::Core::RuntimeLocator.current.__send__(:runtime_state).pipeline
    end

    def configure_runtime_failure_capture(failures)
      Julewire.configure do |config|
        config.destinations.use(:default, output: StringIO.new)
        config.on_failure = ->(error, _metadata) { failures.push(error) }
      end
    end

    def assert_runtime_failure_recorded(previous_runtime_failures)
      assert_equal 1, Julewire.health.dig(:counts, :runtime_failures) - previous_runtime_failures
      assert_equal "RuntimeError", Julewire.health.dig(:last_failure, :class)
      assert_equal :runtime, Julewire.health.dig(:last_failure, :phase)
    end

    def assert_runtime_status_recovers_after_successful_emit
      assert_nil Julewire.emit(message: "recovered")

      assert_equal :ok, Julewire.health.fetch(:status)
      assert_equal "RuntimeError", Julewire.health.dig(:last_failure, :class)
    end

    def failing_summary_runtime
      Class.new(Julewire::Core::Runtime) do
        def emit_summary_record(_scope)
          raise "summary failed"
        end
      end.new
    end
  end
end
