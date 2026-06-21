# frozen_string_literal: true

require "test_helper"
require "support/gcp_test_case"

module Julewire
  class GcpStackTraceTest < GcpTestCase
    cover Julewire::GCP::StackTrace

    def test_keeps_explicit_message_and_nested_error_shape
      record = normalized_record(
        severity: :error,
        message: "request failed",
        error: {
          class: "RuntimeError",
          message: "boom",
          backtrace: ["app.rb:1", "app.rb:2"]
        }
      )

      formatted = formatted_record(record)

      assert_equal(
        {
          severity: "ERROR",
          message: "request failed",
          stack_trace: "RuntimeError: boom\napp.rb:1\napp.rb:2",
          backtrace: nil
        },
        {
          severity: formatted.fetch("severity"),
          message: formatted.fetch("message"),
          stack_trace: formatted["stack_trace"],
          backtrace: formatted.dig("julewire", "error", "backtrace")
        }
      )
    end

    def test_nested_error_shape_keeps_causes
      formatted = format_error(
        error_shape(
          "Julewire::WrappedError",
          "wrapped",
          ["wrapper.rb:1"],
          cause: error_shape("RuntimeError", "boom", ["app.rb:1"])
        )
      )

      assert_equal(
        {
          stack_trace: "Julewire::WrappedError: wrapped\nwrapper.rb:1\nCaused by: RuntimeError: boom\napp.rb:1",
          error_class: "Julewire::WrappedError",
          cause_class: "RuntimeError",
          cause_backtrace: nil
        },
        {
          stack_trace: formatted["stack_trace"],
          error_class: formatted.dig("julewire", "error", "class"),
          cause_class: formatted.dig("julewire", "error", "cause", "class"),
          cause_backtrace: formatted.dig("julewire", "error", "cause", "backtrace")
        }
      )
    end

    def test_uses_error_summary_as_message_when_message_is_blank
      [
        [{ message: "boom" }, "boom"],
        [{ class: "RuntimeError" }, "RuntimeError"]
      ].each do |error, expected|
        formatted = formatted_record(normalized_record(error: error))

        assert_equal expected, formatted.fetch("message")
        assert_nil formatted["stack_trace"]
      end
    end

    def test_uses_request_summary_message_when_message_is_blank
      record = normalized_record(
        kind: :summary,
        event: "request.completed",
        neutral: Core::Fields::AttributeKeys.fields(
          "http.request.method": "GET",
          "url.path": "/boom",
          "http.response.status_code": 500
        ),
        metrics: { duration_ms: 6.901 },
        error: { class: "RuntimeError" }
      )

      formatted = formatted_record(record)

      assert_equal "GET /boom -> 500 RuntimeError in 6.901ms", formatted.fetch("message")
    end

    def test_cloud_logging_message_uses_core_display_message
      record = normalized_record(
        kind: :summary,
        event: "message.consumed",
        neutral: Core::Fields::AttributeKeys.fields(
          "messaging.system": "kafka",
          "messaging.operation.name": "process",
          "messaging.destination.name": "orders",
          "messaging.destination.partition.id": "1",
          "messaging.kafka.offset": "42"
        ),
        metrics: { duration_ms: 4.25 },
        error: { class: "RuntimeError" }
      )

      formatted = formatted_record(record)

      assert_equal Core::Records::DisplayMessage.call(record), formatted.fetch("message")
    end

    private

    def format_error(error)
      formatted_record(normalized_record(severity: :error, error: error))
    end
  end
end
