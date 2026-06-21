# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestCallbackFailureHealth < Minitest::Test
    class FailingOutput
      def write(_value)
        raise "write failed"
      end
    end

    def test_destination_callback_failures_report_last_context
      configure_default_output_with_callback(
        FailingOutput.new,
        :on_failure,
        ->(_error, _metadata) { raise "callback failed" }
      )

      Julewire.emit(message: "output")

      counts = destination_health.fetch(:counts)

      assert_equal 1, counts.fetch(:callback_error)
      assert_equal "RuntimeError", destination_health.dig(:last_callback_failure, :class)
      assert_equal :output, destination_health.dig(:last_callback_failure, :phase)
      assert_equal :default, destination_health.dig(:last_callback_failure, :destination)
    end
  end
end
