# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestExecutionHandle < Minitest::Test
    cover Julewire::Core::Execution::Handle
    def test_deferred_handle_restores_context_and_finishes_once
      records = capture_julewire_records do
        handle = Julewire.start_execution(type: :request, id: "req-1", summary_event: "request.completed")
        handle.run do
          Julewire.context.add(path: "/stream")
          Julewire.emit(message: "inside")
        end

        handle.with_context { Julewire.emit(message: "late") }

        assert_true handle.finish(
          reason: :timeout,
          fields: { completion_timeout_ms: 30_000 },
          attributes: { completion_source: "rack" }
        )
        assert_false handle.finish(reason: :closed)
      end

      inside, late, summary = records

      assert_equal "inside", inside.fetch(:message)
      assert_equal "/stream", inside.dig(:context, :path)
      assert_equal "late", late.fetch(:message)
      assert_equal "/stream", late.dig(:context, :path)
      assert_equal :summary, summary.fetch(:kind)
      assert_equal "request.completed", summary.fetch(:event)
      assert_equal "timeout", summary.dig(:attributes, :"julewire.completion")
      assert_equal "rack", summary.dig(:attributes, :completion_source)
      assert_equal 30_000, summary.dig(:payload, :completion_timeout_ms)
    end

    def test_deferred_handle_records_error_finish_and_reraises
      records = capture_julewire_records do
        handle = Julewire.start_execution(type: :job, id: "job-1")

        assert_raises(RuntimeError) do
          handle.run { raise "failed" }
        end
      end

      summary = records.fetch(0)

      assert_equal :summary, summary.fetch(:kind)
      assert_equal :error, summary.fetch(:severity)
      assert_equal "error", summary.dig(:attributes, :"julewire.completion")
      assert_equal "RuntimeError", summary.dig(:error, :class)
    end

    def test_deferred_handle_run_yields_handle
      yielded = nil

      handle = Julewire.start_execution(type: :job, id: "job-1")
      handle.run { |current| yielded = current }
      handle.finish

      assert_same handle, yielded
    end

    def test_deferred_handle_run_inside_rescue_does_not_record_outer_exception
      records = capture_julewire_records do
        inside_rescue do
          handle = Julewire.start_execution(type: :recovery, summary_event: "recovery.completed")
          handle.run { Julewire.emit(message: "recovering") }

          assert_true handle.finish(reason: :closed)
        end
      end

      summary = records.fetch(1)

      assert_equal :summary, summary.fetch(:kind)
      assert_equal :info, summary.fetch(:severity)
      assert_equal "closed", summary.dig(:attributes, :"julewire.completion")
      assert_nil summary[:error]
    end

    def test_deferred_handle_can_finish_error_with_explicit_summary_severity
      records = capture_julewire_records do
        handle = Julewire.start_execution(type: :request, id: "req-1")
        handle.finish(reason: :error, error: RuntimeError.new("failed"), severity: :warn)
      end

      summary = records.fetch(0)

      assert_equal :summary, summary.fetch(:kind)
      assert_equal :warn, summary.fetch(:severity)
      assert_equal "RuntimeError", summary.dig(:error, :class)
    end

    def test_deferred_handle_default_finish_reason_is_closed
      records = capture_julewire_records do
        handle = Julewire.start_execution(type: :request, id: "req-1")

        assert_true handle.finish
      end

      assert_equal "closed", records.fetch(0).dig(:attributes, :"julewire.completion")
    end

    def test_deferred_handle_exposes_scope_snapshot
      handle = Julewire::Core::Execution::Handle.new(
        scope: build_execution_scope(type: :request, id: "req-1"),
        on_finish: nil,
        on_finish_failure: nil
      )

      snapshot = handle.snapshot

      assert_instance_of Julewire::Core::Execution::View, snapshot
      assert_equal "req-1", snapshot.id
    end

    def test_deferred_handle_allows_missing_finish_callback
      failures = []
      handle = Julewire::Core::Execution::Handle.new(
        scope: build_execution_scope(type: :request),
        on_finish: nil,
        on_finish_failure: ->(error, phase:) { failures << [error, phase] }
      )

      assert_true handle.finish

      assert_empty failures
    end

    def test_deferred_handle_reports_summary_finish_failures
      failures = []
      scope = build_execution_scope(type: :request)
      scope.define_singleton_method(:add_summary) { |_fields| raise "summary failed" }
      handle = Julewire::Core::Execution::Handle.new(
        scope: scope,
        on_finish: ->(_scope) { flunk "finish callback must not run after failed summary mutation" },
        on_finish_failure: ->(error, phase:) { failures << [error.message, phase] }
      )

      assert_false handle.finish(fields: { failed: true })

      assert_equal [["summary failed", :summary_finish]], failures
    end

    def test_deferred_handle_reports_summary_emit_finish_failures
      failures = []
      handle = Julewire::Core::Execution::Handle.new(
        scope: build_execution_scope(type: :request),
        on_finish: ->(_scope) { raise "emit failed" },
        on_finish_failure: ->(error, phase:) { failures << [error.message, phase] }
      )

      assert_true handle.finish

      assert_equal [["emit failed", :summary_emit]], failures
    end

    def test_deferred_handle_swallows_finish_failure_callback_errors
      handle = Julewire::Core::Execution::Handle.new(
        scope: build_execution_scope(type: :request),
        on_finish: ->(_scope) { raise "emit failed" },
        on_finish_failure: ->(_error, phase:) { raise "callback failed in #{phase}" }
      )

      assert_true handle.finish
    end

    def test_deferred_handle_finishes_once_under_concurrent_callers
      finish_scopes = Queue.new
      handle = Julewire::Core::Execution::Handle.new(
        scope: build_execution_scope(type: :request),
        on_finish: ->(scope) { finish_scopes << scope },
        on_finish_failure: nil
      )
      execution_id = handle.snapshot.id
      ready = Queue.new
      start = Queue.new
      threads = Array.new(8) do
        safe_thread do
          ready << true
          start.pop
          handle.finish
        rescue StandardError => e
          e
        end
      end
      threads.size.times { safe_queue_pop(ready) }
      threads.size.times { start << true }

      results = safe_thread_values(threads)

      assert_empty results.grep(StandardError)
      assert_equal 1, results.count(true)
      assert_equal 7, results.count(false)
      assert_equal execution_id, finish_scopes.pop(true).id
      assert_raises(ThreadError) { finish_scopes.pop(true) }
    end

    private

    def inside_rescue
      raise "outer"
    rescue StandardError
      yield
    end
  end
end
