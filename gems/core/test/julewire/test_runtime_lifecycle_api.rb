# frozen_string_literal: true

require "test_helper"
require "json"
require "stringio"

module Julewire
  class TestRuntimeLifecycleApi < Minitest::Test
    cover Julewire::Core::RuntimeLocator
    cover "Julewire::Core::FacadeMethods#after_fork!"
    cover "Julewire::Core::FacadeMethods#close"
    cover "Julewire::Core::FacadeMethods#flush"
    cover "Julewire::Core::FacadeMethods#reset!"
    cover "Julewire::Core::Runtime#call_validated_lifecycle"
    cover "Julewire::Core::Runtime#call_pipeline_lifecycle_on"
    cover "Julewire::Core::Runtime#close"
    cover "Julewire::Core::Runtime#close_state"
    cover "Julewire::Core::Runtime#close_state_resources"
    cover "Julewire::Core::Runtime#clear_runtime_degradation_if_unchanged"
    cover "Julewire::Core::Runtime#flush"
    cover "Julewire::Core::Runtime#increment_lifecycle_attempt"
    cover "Julewire::Core::Runtime#increment_runtime_count"
    cover "Julewire::Core::Runtime#normalize_lifecycle_timeout"
    cover "Julewire::Core::Runtime#notify_failure"
    cover "Julewire::Core::Runtime#runtime_status"
    cover "Julewire::Core::Runtime#runtime_counts_snapshot"
    cover "Julewire::Core::Runtime#reset!"
    cover "Julewire::Core::Runtime#reset_under_lock"
    cover "Julewire::Core::Runtime#replace_pipeline"
    cover "Julewire::Core::Runtime#record_post_close_emit"
    cover "Julewire::Core::Runtime#validate_lifecycle_timeout!"
    class LifecycleOutput
      attr_reader :flush_count

      def write(_value); end

      def flush
        @flush_count = flush_count.to_i + 1
      end
    end

    class TimeoutAwareLifecycleOutput
      attr_reader :closed_timeout, :flushed_timeout

      def write(_value); end

      def flush(timeout:)
        @flushed_timeout = timeout
      end

      def close(timeout:)
        @closed_timeout = timeout
      end
    end

    def test_configure_rejects_flush_from_inside_configure
      assert_runtime_call_rejected_inside_configure(:flush) { Julewire.flush }
    end

    def test_configure_rejects_close_from_inside_configure
      assert_runtime_call_rejected_inside_configure(:close) { Julewire.close }
    end

    class FailingLifecycleOutput
      def write(_value); end

      def flush
        raise "flush failed"
      end
    end

    class CountingCloseOutput
      attr_reader :close_count, :closed_timeout

      def initialize
        @close_count = 0
      end

      def write(_value); end

      def close(timeout: nil)
        @close_count += 1
        @closed_timeout = timeout
      end
    end

    def test_lifecycle_methods_reject_invalid_timeouts
      assert_invalid_lifecycle_timeout { Julewire.flush(timeout: -1) }
      assert_invalid_lifecycle_timeout { Julewire.close(timeout: "slow") }
      assert_invalid_lifecycle_timeout { Julewire.flush(timeout: Float::INFINITY) }
      assert_invalid_lifecycle_timeout { Julewire.flush(timeout: -Float::INFINITY) }
      assert_invalid_lifecycle_timeout { Julewire.flush(timeout: Float::NAN) }
    end

    def test_invalid_close_timeout_leaves_runtime_open
      output = StringIO.new
      Julewire.configure { configure_destination(it, output: output) }

      assert_invalid_lifecycle_timeout { Julewire.close(timeout: "slow") }
      Julewire.emit(message: "still open")

      assert_false Julewire.health.fetch(:closed)
      assert_includes output.string, "still open"
    end

    def test_flush_uses_configured_pipeline_timeout_for_runtime_deadline
      output = TimeoutAwareLifecycleOutput.new

      Julewire.configure do |config|
        configure_destination(config, output: output)
        config.pipeline_close_timeout = 0.25
      end

      Julewire.flush

      assert_lifecycle_timeout 0.25, output.flushed_timeout
    end

    def test_runtime_flush_uses_default_timeout_without_keyword
      output = TimeoutAwareLifecycleOutput.new
      runtime = Julewire.runtime

      Julewire.configure do |config|
        configure_destination(config, output: output)
        config.pipeline_close_timeout = 0.25
      end

      assert_true runtime.flush

      assert_lifecycle_timeout 0.25, output.flushed_timeout
    end

    def test_explicit_nil_flush_timeout_remains_unbounded
      output = TimeoutAwareLifecycleOutput.new

      Julewire.configure do |config|
        configure_destination(config, output: output)
        config.pipeline_close_timeout = 0.25
      end

      Julewire.flush(timeout: nil)

      assert_nil output.flushed_timeout
    end

    def test_close_uses_configured_pipeline_timeout_for_runtime_deadline
      output = TimeoutAwareLifecycleOutput.new

      Julewire.configure do |config|
        configure_destination(config, output: output, close_output: true)
        config.pipeline_close_timeout = 0.25
      end

      Julewire.close

      assert_lifecycle_timeout 0.25, output.closed_timeout
    end

    def test_runtime_close_uses_default_timeout_without_keyword
      output = TimeoutAwareLifecycleOutput.new
      runtime = Julewire.runtime

      Julewire.configure do |config|
        configure_destination(config, output: output, close_output: true)
        config.pipeline_close_timeout = 0.25
      end

      assert_true runtime.close

      assert_lifecycle_timeout 0.25, output.closed_timeout
    end

    def test_close_counts_idempotent_attempts
      Julewire.configure { configure_destination(it, output: StringIO.new) }
      previous_counts = Julewire.health.fetch(:counts)

      assert_true Julewire.close(timeout: nil)
      assert_true Julewire.close(timeout: nil)

      assert_runtime_count_delta Julewire.health, previous_counts, :close_attempts, 2
    end

    def test_reset_closes_previous_pipeline_with_previous_deadline
      output = CountingCloseOutput.new
      Julewire.configure do |config|
        configure_destination(config, output: output, close_output: true)
        config.pipeline_close_timeout = 0.25
      end

      Julewire.reset!

      assert_equal 1, output.close_count
      assert_lifecycle_timeout 0.25, output.closed_timeout
    end

    def test_reset_after_close_does_not_close_old_pipeline_again
      output = CountingCloseOutput.new
      Julewire.configure do |config|
        configure_destination(config, output: output, close_output: true)
      end

      Julewire.close(timeout: 1)
      Julewire.reset!

      assert_equal 1, output.close_count
    end

    def test_flush_after_close_counts_attempt_without_touching_pipeline
      output = LifecycleOutput.new
      Julewire.configure { configure_destination(it, output: output) }

      assert_true Julewire.close(timeout: 1)
      flush_count = output.flush_count.to_i
      previous_counts = Julewire.health.fetch(:counts)

      assert_true Julewire.flush(timeout: 0.01)
      health = Julewire.health

      assert_equal flush_count, output.flush_count.to_i
      assert_runtime_count_delta health, previous_counts, :flush_attempts, 1
    end

    def test_successful_flush_clears_runtime_lifecycle_degradation
      failures = Queue.new
      output = LifecycleOutput.new
      Julewire.configure do |config|
        configure_destination(config, output: output)
        config.on_failure = ->(error, _metadata) { failures << error }
      end
      pipeline = active_pipeline
      previous_counts = Julewire.health.fetch(:counts)

      with_overridden_singleton_method(pipeline, :emit, proc { |_record, **| raise "emit failed" }) do
        assert_nil Julewire.emit(message: "lost")
      end
      assert_equal :degraded, Julewire.health.fetch(:status)

      assert_true Julewire.flush
      health = Julewire.health

      assert_equal "emit failed", safe_queue_pop(failures).message
      assert_equal 1, output.flush_count
      assert_equal :ok, health.fetch(:status)
      assert_runtime_count_delta health, previous_counts, :runtime_failures, 1
    end

    def test_reconfigure_clears_previous_runtime_failure_degradation
      failures = Queue.new
      Julewire.configure do |config|
        configure_destination(config, output: StringIO.new)
        config.on_failure = ->(error, _metadata) { failures << error }
      end
      pipeline = active_pipeline
      previous_counts = Julewire.health.fetch(:counts)

      with_overridden_singleton_method(pipeline, :emit, proc { |_record, **| raise "emit failed" }) do
        assert_nil Julewire.emit(message: "lost")
      end
      assert_equal :degraded, Julewire.health.fetch(:status)

      Julewire.configure { configure_destination(it, output: StringIO.new) }
      health = Julewire.health

      assert_equal "emit failed", safe_queue_pop(failures).message
      assert_equal :ok, health.fetch(:status)
      assert_equal "RuntimeError", health.dig(:last_failure, :class)
      assert_runtime_count_delta health, previous_counts, :runtime_failures, 1
    end

    def test_failed_flush_result_does_not_clear_runtime_degradation
      Julewire.configure { configure_destination(it, output: StringIO.new) }
      pipeline = active_pipeline

      with_overridden_singleton_method(pipeline, :emit, proc { |_record, **| raise "emit failed" }) do
        assert_nil Julewire.emit(message: "lost")
      end
      with_overridden_singleton_method(pipeline, :flush, proc { |**| false }) do
        assert_false Julewire.flush
      end

      health = Julewire.health

      assert_equal :degraded, health.fetch(:status)
      assert_equal :runtime, health.dig(:last_failure, :phase)
      assert_equal :emit, health.dig(:last_failure, :action)
    end

    def test_pipeline_lifecycle_exceptions_use_runtime_failure_callback
      assert_pipeline_lifecycle_exception(:flush, "pipeline flush failed")
    end

    def test_pipeline_close_exceptions_use_closing_state_failure_callback
      assert_pipeline_lifecycle_exception(:close, "pipeline close failed")
    end

    def assert_pipeline_lifecycle_exception(action, message)
      failures = configure_runtime_failure_capture(Julewire.runtime)
      pipeline = active_pipeline
      previous_counts = Julewire.health.fetch(:counts)

      with_overridden_singleton_method(pipeline, action, proc { |**| raise message }) do
        assert_false Julewire.public_send(action, timeout: 0.25)
      end

      error, metadata = failures.pop(timeout: 1)
      health = Julewire.health

      assert_equal message, error.message
      assert_equal :runtime, metadata.fetch(:phase)
      assert_equal action, metadata.fetch(:action)
      assert_runtime_count_delta health, previous_counts, :runtime_failures, 1
    end

    def test_lifecycle_failure_uses_configured_failure_callback
      failures = Queue.new
      Julewire.configure do |config|
        configure_destination(config, output: FailingLifecycleOutput.new)
        config.on_failure = ->(error, metadata) { failures << [error, metadata] }
      end

      assert_false Julewire.flush(timeout: 0.25)

      error, metadata = failures.pop(timeout: 1)

      assert_equal "flush failed", error.message
      assert_equal :output_lifecycle, metadata.fetch(:phase)
      assert_equal :flush, metadata.fetch(:action)
    end

    def test_emit_after_close_is_noop_until_reconfigure
      output = StringIO.new
      drops = configure_output_with_drop_capture(output)

      Julewire.emit(message: "before")

      assert_true Julewire.close(timeout: 1)

      Julewire.emit(message: "after")

      reason, metadata = drops.pop(timeout: 1)
      health = Julewire.health

      assert_includes output.string, "before"
      refute_includes output.string, "after"
      assert_equal :runtime_closed, reason
      assert_equal :runtime, metadata.fetch(:phase)
      assert_true health.fetch(:closed)
      assert_equal :closed, health.fetch(:status)
      assert_equal 1, health.dig(:counts, :post_close_emits)
      assert_equal 1, health.dig(:pipeline, :counts, :entered)
    end

    def test_post_close_drop_callback_failures_are_counted
      output = StringIO.new
      failures = Queue.new
      Julewire.configure do |config|
        configure_destination(config, output: output)
        config.on_drop = ->(_reason, _metadata) { raise "drop callback failed" }
        config.on_failure = ->(error, _metadata) { failures << error }
      end

      Julewire.close(timeout: 1)
      previous_counts = Julewire.health.fetch(:counts)

      assert_nil Julewire.emit(message: "after")

      health = Julewire.health

      assert_empty output.string
      assert_empty nonblocking_queue_values(failures)
      assert_equal 1, health.dig(:counts, :post_close_emits)
      assert_equal "RuntimeError", health.dig(:last_callback_failure, :class)
      assert_equal :runtime, health.dig(:last_callback_failure, :phase)
      assert_runtime_count_delta health, previous_counts, :post_close_emits_total, 1
      assert_runtime_count_delta health, previous_counts, :runtime_callback_failures, 1
      assert_runtime_count_delta health, previous_counts, :runtime_failures, 0
    end

    def test_post_close_drop_callbacks_fire_for_each_drop
      drops = Queue.new
      Julewire.configure do |config|
        configure_destination(config, output: StringIO.new)
        config.on_drop = ->(reason, _metadata) { drops << reason }
      end
      previous_counts = Julewire.health.fetch(:counts)

      Julewire.close(timeout: 1)
      2.times { Julewire.emit(message: "after") }

      health = Julewire.health

      assert_equal %i[runtime_closed runtime_closed], nonblocking_queue_values(drops)
      assert_equal 2, health.dig(:counts, :post_close_emits)
      assert_runtime_count_delta health, previous_counts, :post_close_emits_total, 2
    end

    def test_reset_installs_frozen_default_configuration
      Julewire.configure do |config|
        config.level = :fatal
        configure_destination(config, output: StringIO.new)
      end

      Julewire.reset!

      assert_predicate Julewire.config, :frozen?
      assert_equal :debug, Julewire.config.level
      assert_predicate Julewire.config.destinations, :empty?
      assert_raises(FrozenError) { Julewire.config.level = :info }
    end

    def test_reset_clears_runtime_failures_integration_health_and_current_post_close_count
      runtime = Julewire.runtime
      Julewire.configure { configure_destination(it, output: StringIO.new) }
      previous_counts = Julewire.health.fetch(:counts)
      pipeline = active_pipeline

      with_overridden_singleton_method(pipeline, :emit, proc { |_record, **| raise "emit failed" }) do
        Julewire.emit(message: "lost")
      end
      runtime.record_integration_failure(:runtime_adapter, RuntimeError.new("runtime integration failed"))
      Julewire::Core::Diagnostics::ProcessIntegrationHealth.record_failure(
        :process_adapter,
        RuntimeError.new("process integration failed")
      )
      Julewire.close(timeout: 1)
      Julewire.emit(message: "after close")

      Julewire.reset!
      health = Julewire.health

      assert_nil health.fetch(:last_failure)
      assert_empty health.fetch(:integrations)
      assert_empty health.fetch(:process_integrations)
      assert_equal 0, health.dig(:counts, :post_close_emits)
      assert_runtime_count_delta health, previous_counts, :runtime_failures, 1
      assert_runtime_count_delta health, previous_counts, :post_close_emits_total, 1
    end

    def test_reset_clears_current_context
      Julewire.context.add(request_id: "stale-request")

      Julewire.reset!

      output = StringIO.new
      Julewire.configure { configure_destination(it, output: output) }
      Julewire.emit(message: "fresh")

      assert_false JSON.parse(output.string).key?("context")
    end

    def test_reconfigure_after_close_installs_fresh_open_pipeline
      first_output = StringIO.new
      second_output = StringIO.new
      previous_counts = Julewire.health.fetch(:counts)

      Julewire.configure { configure_destination(it, output: first_output) }
      Julewire.close(timeout: 1)
      Julewire.emit(message: "dropped")

      Julewire.configure { configure_destination(it, output: second_output) }
      Julewire.emit(message: "written")

      health = Julewire.health

      assert_false health.fetch(:closed)
      assert_equal 0, health.dig(:counts, :post_close_emits)
      assert_runtime_count_delta health, previous_counts, :post_close_emits_total, 1
      refute_includes first_output.string, "dropped"
      assert_includes second_output.string, "written"
    end

    private

    def assert_invalid_lifecycle_timeout(&)
      error = assert_raises(ArgumentError, &)

      assert_match "timeout must be nil or a non-negative finite Numeric", error.message
    end

    def assert_lifecycle_timeout(expected, actual)
      refute_nil actual
      assert_operator actual, :>, 0
      assert_operator actual, :<=, expected
      assert_in_delta expected, actual, 0.05
    end

    def active_pipeline
      Julewire::Core::RuntimeLocator.current.__send__(:runtime_state).pipeline
    end

    def assert_runtime_count_delta(health, previous_counts, key, expected_delta)
      assert_equal expected_delta, health.dig(:counts, key) - previous_counts.fetch(key)
    end
  end
end
