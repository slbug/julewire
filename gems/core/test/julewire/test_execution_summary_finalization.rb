# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestExecutionSummaryFinalization < Minitest::Test
    cover Julewire::Core::Execution::SummaryState
    cover "Julewire::Core::Execution::Scope#measure_summary"
    cover "Julewire::Core::Execution::Scope#measure_summary_start"
    cover "Julewire::Core::Execution::Scope#finish_owned"
    cover "Julewire::Core::ContextStore#with_execution"

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
      assert_equal started_at + 10_000, first_input.fetch(:timestamp)
      assert_equal started_at + 10_000, second_input.fetch(:timestamp)
      assert_equal 1000, scope.metrics_hash[:duration_ms]
      assert_false first_input.key?(:severity)
    end

    def test_execution_scope_finish_returns_summary_input_without_building_record
      scope = build_execution_scope(type: :job)

      build_calls = count_record_build_calls do
        scope.finish_owned
      end

      assert_equal 0, build_calls
    end

    def test_execution_scope_finish_defaults_to_frozen_utc_now
      scope = build_execution_scope(type: :job, started_at: Time.utc(2026, 1, 1))
      wall_clock = Time.new(2026, 1, 2, 3, 4, 5, "+02:00")

      input = with_overridden_singleton_method(Time, :now, proc { wall_clock }) do
        scope.finish_owned
      end

      timestamp = input.fetch(:timestamp)

      assert_equal wall_clock.utc, timestamp
      assert_same scope.finished_at, timestamp
      assert_predicate timestamp, :utc?
      assert_predicate timestamp, :frozen?
    end

    def test_execution_scope_finish_stores_frozen_finish_time_copy
      finished_at = Time.utc(2026, 1, 2, 3, 4, 5)
      scope = build_execution_scope(type: :job, started_at: Time.utc(2026, 1, 1))

      input = scope.finish_owned(finished_at: finished_at)
      timestamp = input.fetch(:timestamp)

      assert_equal finished_at, timestamp
      assert_same scope.finished_at, timestamp
      refute_same finished_at, timestamp
      assert_predicate timestamp, :frozen?
    end

    def test_execution_scope_finish_records_duration_with_millisecond_precision
      scope = nil

      with_monotonic_times(100.0, 100.1234567) do
        scope = build_execution_scope(type: :job, started_at: Time.utc(2026, 1, 1))
        scope.finish_owned(finished_at: Time.utc(2026, 1, 1, 0, 0, 1))
      end

      assert_equal 123.457, scope.metrics_hash.fetch(:duration_ms) # rubocop:disable Minitest/AssertInDelta
    end

    def test_fresh_unfinished_summary_record_input_is_warning_free
      scope = build_execution_scope(type: :job, started_at: Time.utc(2026, 1, 1))

      _stdout, stderr = capture_io do
        assert_equal :summary, scope.owned_summary_record_input.fetch(:kind)
      end

      assert_empty stderr
    end

    def test_error_summary_without_explicit_severity_is_warning_free
      scope = build_execution_scope(type: :job, started_at: Time.utc(2026, 1, 1))
      scope.record_error(RuntimeError.new("boom"))

      _stdout, stderr = capture_io do
        assert_equal :error, scope.owned_summary_record_input.fetch(:severity)
      end

      assert_empty stderr
    end

    def test_error_summary_normalizes_explicit_error_severity
      scope = build_execution_scope(type: :job, started_at: Time.utc(2026, 1, 1))

      scope.record_error(RuntimeError.new("boom"), severity: "WARN")

      assert_equal :warn, scope.owned_summary_record_input.fetch(:severity)
    end

    def test_finish_owned_records_error_and_explicit_severity
      scope = build_execution_scope(type: :job, started_at: Time.utc(2026, 1, 1))
      error = RuntimeError.new("boom")

      input = scope.finish_owned(error: error, severity: "WARN", finished_at: Time.utc(2026, 1, 2))

      assert_equal :warn, input.fetch(:severity)
      assert_same error, input.fetch(:error)
    end

    def test_measure_summary_records_duration_with_millisecond_precision
      scope = nil

      with_monotonic_times(100.0, 100.25, 100.3734567) do
        scope = build_execution_scope(type: :job, started_at: Time.utc(2026, 1, 1))
        scope.measure_summary(:render) { :ok }
      end

      assert_equal 1, scope.summary_hash.fetch(:render_count)
      assert_equal 123.457, scope.metrics_hash.fetch(:render_duration_ms) # rubocop:disable Minitest/AssertInDelta
    end

    def test_measure_summary_start_records_duration_with_millisecond_precision
      scope = nil

      with_monotonic_times(100.0, 100.25, 100.3734567) do
        scope = build_execution_scope(type: :job, started_at: Time.utc(2026, 1, 1))
        handle = scope.measure_summary_start(:render)
        handle.finish
      end

      assert_equal 1, scope.summary_hash.fetch(:render_count)
      assert_equal 123.457, scope.metrics_hash.fetch(:render_duration_ms) # rubocop:disable Minitest/AssertInDelta
    end

    def test_owned_summary_record_input_uses_frozen_utc_now_for_unfinished_scope
      assert_summary_record_input_uses_frozen_utc_now(:owned_summary_record_input)
    end

    def test_summary_record_input_uses_frozen_utc_now_for_unfinished_scope
      assert_summary_record_input_uses_frozen_utc_now(:summary_record_input)
    end

    def assert_summary_record_input_uses_frozen_utc_now(method_name)
      scope = build_execution_scope(type: :job, started_at: Time.utc(2026, 1, 1))
      wall_clock = Time.new(2026, 1, 2, 3, 4, 5, "+02:00")

      input = with_overridden_singleton_method(Time, :now, proc { wall_clock }) do
        scope.public_send(method_name)
      end

      timestamp = input.fetch(:timestamp)

      assert_equal wall_clock.utc, timestamp
      assert_predicate timestamp, :utc?
      assert_predicate timestamp, :frozen?
    end

    def test_owned_summary_record_input_reuses_finished_timestamp
      assert_summary_record_input_reuses_finished_timestamp(:owned_summary_record_input)
    end

    def test_summary_record_input_reuses_finished_timestamp
      assert_summary_record_input_reuses_finished_timestamp(:summary_record_input)
    end

    def assert_summary_record_input_reuses_finished_timestamp(method_name)
      finished_at = Time.utc(2026, 1, 2, 3, 4, 5)
      wall_clock = Time.utc(2027, 1, 2, 3, 4, 5)
      scope = build_execution_scope(type: :job, started_at: Time.utc(2026, 1, 1))
      scope.finish_owned(finished_at: finished_at)

      input = with_overridden_singleton_method(Time, :now, proc { wall_clock }) do
        scope.public_send(method_name)
      end

      assert_equal finished_at, input.fetch(:timestamp)
    end

    def test_owned_summary_record_input_carries_scope_and_summary_sections
      scope = build_execution_scope(
        type: :request,
        id: "req-1",
        execution: { trace_id: "trace-1" },
        context: { request_id: "ctx-1" },
        carry: { traceparent: "traceparent-1" },
        neutral: { runtime: "node-a" },
        attributes: { tenant: "acme" },
        labels: { service: "web" },
        summary_event: "request.completed",
        summary_source: "web"
      )
      scope.add_summary({ status: 200 })
      scope.add_summary_attributes({ http: { status: 200 } })
      scope.add_summary_neutral({ worker: { node: "worker-a" } })
      scope.record_error(RuntimeError.new("boom"), severity: :warn)

      input = scope.owned_summary_record_input

      assert_equal :summary, input.fetch(:kind)
      assert_equal :warn, input.fetch(:severity)
      assert_equal "request.completed", input.fetch(:event)
      assert_equal "web", input.fetch(:source)
      assert_equal "req-1", input.dig(:execution, :id)
      assert_equal "request", input.dig(:execution, :type)
      assert_equal "trace-1", input.dig(:execution, :trace_id)
      assert_equal "ctx-1", input.dig(:context, :request_id)
      assert_equal "traceparent-1", input.dig(:carry, :traceparent)
      assert_equal "node-a", input.dig(:neutral, :runtime)
      assert_equal "worker-a", input.dig(:neutral, :worker, :node)
      assert_equal "acme", input.dig(:attributes, :tenant)
      assert_equal 200, input.dig(:attributes, :http, :status)
      assert_equal "web", input.dig(:labels, :service)
      assert_equal 200, input.dig(:payload, :status)
      assert_equal "boom", input.fetch(:error).message
    end

    def test_owned_summary_record_input_merges_owned_truncated_sections
      limit = Core::Serialization::Serializer::DEFAULT_MAX_STRING_BYTES
      long_value = "x" * (limit + 1)
      scope = build_execution_scope(
        type: :request,
        attributes: { base: { note: long_value } },
        neutral: { base: { note: long_value } }
      )
      scope.add_summary_attributes({ summary: { note: long_value } })
      scope.add_summary_neutral({ summary: { note: long_value } })

      input = scope.owned_summary_record_input

      assert_symbol_truncation_metadata input.dig(:attributes, :base, :_julewire_truncation),
                                        fields: ["note"],
                                        max_string_bytes: limit
      assert_symbol_truncation_metadata input.dig(:attributes, :summary, :_julewire_truncation),
                                        fields: ["note"],
                                        max_string_bytes: limit
      assert_symbol_truncation_metadata input.dig(:neutral, :base, :_julewire_truncation),
                                        fields: ["note"],
                                        max_string_bytes: limit
      assert_symbol_truncation_metadata input.dig(:neutral, :summary, :_julewire_truncation),
                                        fields: ["note"],
                                        max_string_bytes: limit
    end

    def test_finish_scope_reports_finish_failure_and_still_runs_finalizer
      scope = Class.new do
        def finished? = false

        def finish_owned
          raise "finish failed"
        end
      end.new
      reports = []

      finish_scope_for_test(scope, reports)

      assert_equal [["finish failed", :summary_finish], :finalized], reports
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
      assert_nil scope.finished
    end

    def test_finish_scope_does_not_finish_already_finished_scope
      scope = Class.new do
        attr_reader :finish_calls

        def initialize
          @finish_calls = 0
        end

        def finished? = true

        def finish_owned
          @finish_calls += 1
        end
      end.new
      reports = []

      finish_scope_for_test(scope, reports)

      assert_equal 0, scope.finish_calls
      assert_equal [:finalized], reports
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

    def test_finish_scope_reports_system_stack_finish_failure_when_unwinding_active_exception
      scope = Class.new do
        def finished? = false

        def finish_owned
          raise SystemStackError, "finish failed"
        end
      end.new
      reports = []
      active_exception = RuntimeError.new("application failed")

      Julewire::Core::ContextStore.new.__send__(
        :finish_scope,
        scope,
        ->(_scope) { reports << :finalized },
        ->(error, phase:) { reports << [error.message, phase] },
        active_exception: active_exception
      )

      assert_equal [["finish failed", :summary_finish], :finalized], reports
    end

    def test_finish_scope_reports_system_stack_emit_failure_when_unwinding_active_exception
      scope = build_execution_scope(type: :request)
      reports = []
      active_exception = RuntimeError.new("application failed")

      Julewire::Core::ContextStore.new.__send__(
        :finish_scope,
        scope,
        ->(_scope) { raise SystemStackError, "emit failed" },
        ->(error, phase:) { reports << [error.message, phase] },
        active_exception: active_exception
      )

      assert_equal [["emit failed", :summary_emit]], reports
    end

    def test_finish_scope_reraises_system_stack_finish_failure_without_active_exception
      scope = Class.new do
        def finished? = false

        def finish_owned
          raise SystemStackError, "finish failed"
        end
      end.new

      error = assert_raises(SystemStackError) do
        Julewire::Core::ContextStore.new.__send__(
          :finish_scope,
          scope,
          ->(_scope) { :finalized },
          nil
        )
      end

      assert_equal "finish failed", error.message
    end

    def test_finish_scope_reraises_system_stack_emit_failure_without_active_exception
      scope = build_execution_scope(type: :request)

      error = assert_raises(SystemStackError) do
        Julewire::Core::ContextStore.new.__send__(
          :finish_scope,
          scope,
          ->(_scope) { raise SystemStackError, "emit failed" },
          nil
        )
      end

      assert_equal "emit failed", error.message
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

    def finish_scope_for_test(scope, reports)
      Julewire::Core::ContextStore.new.__send__(
        :finish_scope,
        scope,
        ->(_scope) { reports << :finalized },
        ->(error, phase:) { reports << [error.message, phase] }
      )
    end

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
