# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestPipelineNoOutputHealth < Minitest::Test
    def test_no_output_emits_are_counted
      Julewire.emit(message: "no sink")
      Julewire.emit(message: "still no sink")

      counts = Julewire.health.dig(:pipeline, :counts)

      assert_equal 2, counts.fetch(:no_output_dropped)
      assert_equal 0, counts.fetch(:entered)
    end
  end
end
