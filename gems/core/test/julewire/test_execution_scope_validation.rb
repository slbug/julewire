# frozen_string_literal: true

require "test_helper"
require "json"
require "stringio"

module Julewire
  class TestExecutionScopeValidation < Minitest::Test
    cover "Julewire::Core::ContextStore#merged_execution_hash"
    cover Julewire::Core::Execution::Boundary
    cover "Julewire::Core::Execution::Boundary#open_context_execution"
    cover "Julewire::Core::Execution::Boundary#start_execution"
    cover "Julewire::Core::Execution::Boundary#with_execution"
    cover "Julewire::Core::ContextStore#build_scope"
    cover "Julewire::Core::Execution::Scope#normalize_summary_event"
    cover "Julewire::Core::Execution::Scope#normalize_summary_source"
    cover "Julewire::Core::Runtime#build_execution_boundary"
    cover "Julewire::Core::Runtime#before_execution_boundary_call!"

    def test_with_execution_rejects_missing_type
      error = assert_raises(ArgumentError) do
        Julewire.with_execution(type: nil, emit_summary: false) { flunk "should not run" }
      end

      assert_equal "execution type is required", error.message
    end

    def test_execution_options_validate_public_shapes
      error = assert_raises(ArgumentError) { Julewire.with_execution(type: :job, fields: "trace-1") { :unused } }

      assert_equal "execution fields must be a Hash", error.message
      error = assert_raises(ArgumentError) { Julewire.with_execution(type: :job, summary_event: "") { :unused } }
      assert_equal "summary event is required", error.message
    end

    def test_summary_event_is_stringified_for_summary_records
      event = Object.new
      event.define_singleton_method(:to_s) { "worker.completed" }

      records = capture_julewire_records do
        Julewire.with_execution(type: :job, summary_event: event) { :done }
      end

      assert_equal "worker.completed", records.fetch(0).fetch(:event)
    end

    def test_summary_defaults_use_execution_type_and_julewire_source
      records = capture_julewire_records do
        Julewire.with_execution(type: :job) { :done }
      end

      assert_equal "job.completed", records.fetch(0).fetch(:event)
      assert_equal "julewire", records.fetch(0).fetch(:source)
    end

    def test_execution_options_reject_empty_summary_source_with_clear_message
      error = assert_raises(ArgumentError) do
        Julewire.with_execution(type: :job, summary_source: "") { :unused }
      end

      assert_equal "summary source is required", error.message
    end

    def test_summary_source_is_stringified_for_summary_records
      source = Object.new
      source.define_singleton_method(:to_s) { "worker-source" }

      records = capture_julewire_records do
        Julewire.with_execution(type: :job, summary_source: source) { :done }
      end

      assert_equal "worker-source", records.fetch(0).fetch(:source)
    end

    def test_summary_severity_is_normalized_for_summary_records
      records = capture_julewire_records do
        Julewire.with_execution(type: :job, summary_severity: "WARN") { :done }
      end

      assert_equal :warn, records.fetch(0).fetch(:severity)
    end

    def test_emit_summary_false_skips_summary_record
      records = capture_julewire_records do
        Julewire.with_execution(type: :job, emit_summary: false) { :done }
      end

      assert_empty records
    end

    def test_execution_options_reject_unknown_public_fields
      error = assert_raises(ArgumentError) do
        Julewire.with_execution(type: :job, attributes_owned: true) { :unused }
      end

      assert_equal "unknown execution options: attributes_owned", error.message
    end

    def test_execution_options_report_multiple_unknown_public_fields
      error = assert_raises(ArgumentError) do
        Julewire.with_execution(type: :job, one: true, two: true) { :unused }
      end

      assert_equal "unknown execution options: one, two", error.message
    end

    def test_runtime_execution_options_require_type
      runtime = Julewire::Core::Runtime.new

      assert_raises(ArgumentError) { runtime.with_execution(emit_summary: false) { :unused } }
    end

    def test_runtime_execution_boundary_emits_summary_record_from_new_runtime
      runtime = Julewire::Core::Runtime.new
      output = StringIO.new
      runtime.configure { configure_destination(it, output: output) }

      runtime.with_execution(type: :job) { :done }

      record = JSON.parse(output.string)

      assert_equal "summary", record.fetch("kind")
      assert_equal "job.completed", record.fetch("event")
    ensure
      runtime&.close
    end

    def test_runtime_execution_boundary_rejects_with_execution_inside_runtime_configure
      runtime = Julewire::Core::Runtime.new

      error = assert_raises(Julewire::Core::Error) do
        runtime.configure { runtime.with_execution(type: :job, emit_summary: false) { :unused } }
      end

      assert_equal "Julewire.with_execution cannot be called from inside Julewire.configure", error.message
    ensure
      runtime&.close
    end

    def test_execution_boundary_allows_missing_before_call_callback
      boundary = Julewire::Core::Execution::Boundary.new(
        emit_summary_record: ->(_scope) {},
        summary_finalizer_failure: ->(_error, _metadata) {},
        emit_non_standard_exception_summaries: true
      )

      assert_equal :done, boundary.with_execution(type: :job, emit_summary: false) { :done }
    end

    def test_execution_boundary_preserves_owned_scope_validation
      boundary = Julewire::Core::Execution::Boundary.new(
        emit_summary_record: ->(_scope) {},
        summary_finalizer_failure: ->(_error, _metadata) {},
        emit_non_standard_exception_summaries: true
      )

      error = assert_raises(TypeError) do
        boundary.with_execution(
          type: :job,
          fields: { payload: { "job_id" => "job-1" } },
          owned: true,
          emit_summary: false
        ) { :unreachable }
      end

      assert_equal Julewire::Core::Fields::Internal::RECORD_STRING_KEY_ERROR, error.message
    end

    def test_execution_boundary_invokes_before_call_callback
      actions = []
      boundary = Julewire::Core::Execution::Boundary.new(
        emit_summary_record: ->(_scope) {},
        summary_finalizer_failure: ->(_error, _metadata) {},
        emit_non_standard_exception_summaries: -> { true },
        before_call: ->(action) { actions << action }
      )

      boundary.with_execution(type: :job, emit_summary: false) { :done }

      assert_equal [:with_execution], actions
    end

    def test_execution_boundary_reports_summary_finalizer_failures
      failures = []
      boundary = Julewire::Core::Execution::Boundary.new(
        emit_summary_record: ->(_scope) { raise "summary failed" },
        summary_finalizer_failure: ->(error, phase:) { failures << [error.message, phase] },
        emit_non_standard_exception_summaries: -> { true }
      )

      assert_equal :done, boundary.with_execution(type: :job) { :done }

      assert_equal [["summary failed", :summary_emit]], failures
    end

    def test_configure_rejects_with_execution_calls
      error = assert_raises(Julewire::Core::Error) do
        Julewire.configure do
          Julewire.with_execution(type: :job) { :unused }
        end
      end

      assert_equal "Julewire.with_execution cannot be called from inside Julewire.configure", error.message
    end

    def test_configure_rejects_start_execution_calls
      error = assert_raises(Julewire::Core::Error) do
        Julewire.configure do
          Julewire.start_execution(type: :job)
        end
      end

      assert_equal "Julewire.start_execution cannot be called from inside Julewire.configure", error.message
    end
  end
end
