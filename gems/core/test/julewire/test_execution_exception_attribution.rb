# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestExecutionExceptionAttribution < Minitest::Test
    def test_with_execution_inside_rescue_does_not_record_outer_exception
      records = capture_julewire_records do
        inside_rescue do
          Julewire.with_execution(type: :recovery, summary_event: "recovery.completed") do
            Julewire.emit(message: "recovering")
          end
        end
      end

      summary = records.fetch(1)

      assert_equal :summary, summary.fetch(:kind)
      assert_equal :info, summary.fetch(:severity)
      assert_nil summary[:error]
    end

    private

    def inside_rescue
      raise "outer"
    rescue StandardError
      yield
    end
  end
end
