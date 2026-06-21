# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestExecutionSummaryMetadata < Minitest::Test
    def test_with_execution_can_set_summary_source_and_event
      records = capture_request_summary_records

      summary = records.fetch(0)

      assert_equal "web", summary.fetch(:source)
      assert_equal "request.completed", summary.fetch(:event)
      assert_equal 200, summary.dig(:payload, :status)
    end

    def test_explicit_success_summary_severity_is_used
      records = capture_julewire_records do
        Julewire.with_execution(
          type: :request,
          summary_event: "request.completed",
          summary_severity: :debug,
          summary_source: "web"
        ) do
          Julewire.summary.add(status: 200)
        end
      end

      assert_equal :debug, records.fetch(0).fetch(:severity)
    end

    def test_error_summary_stays_error_with_explicit_summary_severity
      records = capture_julewire_records do
        assert_raises(RuntimeError) do
          Julewire.with_execution(
            type: :request,
            summary_event: "request.completed",
            summary_severity: :debug,
            summary_source: "web"
          ) do
            raise "boom"
          end
        end
      end

      assert_equal :error, records.fetch(0).fetch(:severity)
    end

    private

    def capture_request_summary_records
      capture_julewire_records do
        Julewire.with_execution(
          type: :request,
          summary_event: "request.completed",
          summary_source: "web"
        ) do
          Julewire.summary.add(status: 200)
        end
      end
    end
  end
end
