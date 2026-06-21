# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestExecutionHandle < Minitest::Test
    def test_deferred_handle_restores_context_and_finishes_once
      records = capture_julewire_records do
        handle = Julewire.start_execution(type: :request, id: "req-1", summary_event: "request.completed")
        handle.run do
          Julewire.context.add(path: "/stream")
          Julewire.emit(message: "inside")
        end

        handle.with_context { Julewire.emit(message: "late") }

        assert handle.finish(reason: :timeout, fields: { completion_timeout_ms: 30_000 })
        refute handle.finish(reason: :closed)
      end

      inside, late, summary = records

      assert_equal "inside", inside.fetch(:message)
      assert_equal "/stream", inside.dig(:context, :path)
      assert_equal "late", late.fetch(:message)
      assert_equal "/stream", late.dig(:context, :path)
      assert_equal :summary, summary.fetch(:kind)
      assert_equal "request.completed", summary.fetch(:event)
      assert_equal "timeout", summary.dig(:attributes, :"julewire.completion")
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

    def test_deferred_handle_run_inside_rescue_does_not_record_outer_exception
      records = capture_julewire_records do
        inside_rescue do
          handle = Julewire.start_execution(type: :recovery, summary_event: "recovery.completed")
          handle.run { Julewire.emit(message: "recovering") }

          assert handle.finish(reason: :closed)
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

    private

    def inside_rescue
      raise "outer"
    rescue StandardError
      yield
    end
  end
end
