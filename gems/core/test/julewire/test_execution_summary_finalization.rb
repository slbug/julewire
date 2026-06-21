# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestExecutionSummaryFinalization < Minitest::Test
    def test_execution_scope_finish_captures_summary_input_once
      started_at = Time.utc(2026, 1, 1)
      scope = nil
      first_input = nil
      second_input = nil

      with_monotonic_times(100.0, 101.0) do
        scope = build_execution_scope(type: :job, started_at: started_at)
        first_input = scope.finish_owned(finished_at: started_at + 10_000)
        second_input = scope.finish_owned(error: RuntimeError.new("late"), finished_at: started_at + 20_000)
      end

      assert_equal first_input, second_input
      assert_equal :summary, first_input.fetch(:kind)
      assert_equal 1000, scope.metrics_hash[:duration_ms]
      refute first_input.key?(:severity)
    end

    def test_execution_scope_finish_returns_summary_input_without_building_record
      scope = build_execution_scope(type: :job)

      build_calls = count_record_build_calls do
        scope.finish_owned
      end

      assert_equal 0, build_calls
    end

    def test_finish_scope_reports_finish_failure_and_still_runs_finalizer
      scope = Class.new do
        def finished? = false

        def finish_owned
          raise "finish failed"
        end
      end.new
      reports = []

      Julewire::Core::ContextStore.new.__send__(
        :finish_scope,
        scope,
        ->(_scope) { reports << :finalized },
        ->(error) { reports << error.message }
      )

      assert_equal ["finish failed", :finalized], reports
    end

    def test_finish_scope_skips_finish_without_finalizer
      scope = Class.new do
        attr_reader :finished

        def finished? = false

        def finish_owned
          @finished = true
        end
      end.new
      failures = []

      Julewire::Core::ContextStore.new.__send__(
        :finish_scope,
        scope,
        nil,
        ->(error) { failures << error }
      )

      assert_empty failures
      refute scope.finished
    end

    def test_finish_scope_preserves_active_application_exception_over_standard_finalizer_failure
      store = Julewire::Core::ContextStore.new

      error = assert_raises(RuntimeError) do
        store.with_execution(type: :request, on_finish: ->(_scope) { raise "finalizer failed" }) do
          raise "application failed"
        end
      end

      assert_equal "application failed", error.message
    end

    def test_finish_scope_preserves_active_application_exception_over_system_stack_finalizer_failure
      store = Julewire::Core::ContextStore.new

      error = assert_raises(RuntimeError) do
        store.with_execution(type: :request, on_finish: ->(_scope) { raise SystemStackError, "finalizer failed" }) do
          raise "application failed"
        end
      end

      assert_equal "application failed", error.message
    end

    def test_finish_scope_still_raises_non_standard_finalizer_failure_without_active_exception
      finalizer_error = Class.new(Exception) # rubocop:disable Lint/InheritException
      scope = build_execution_scope(type: :request)

      assert_raises(finalizer_error) do
        Julewire::Core::ContextStore.new.__send__(
          :finish_scope,
          scope,
          ->(_scope) { raise finalizer_error, "finalizer failed" },
          nil
        )
      end
    end

    private

    def count_record_build_calls(&)
      record = Julewire::Core::Records::Draft
      original_build = record.method(:build)
      calls = 0
      replacement = proc do |*args, **kwargs|
        calls += 1
        original_build.call(*args, **kwargs)
      end

      with_overridden_singleton_method(record, :build, replacement, &)
      calls
    end
  end
end
