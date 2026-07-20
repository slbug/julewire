# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestPipelineNoOutputHealth < Minitest::Test
    cover Julewire::Core::Processing::Pipeline
    cover "Julewire::Core::Processing::Pipeline#emit_input_with_guard"
    cover "Julewire::Core::Processing::Pipeline#health"
    def test_no_output_emits_are_counted
      Julewire.emit(message: "no sink")
      Julewire.emit(message: "still no sink")

      counts = Julewire.health.dig(:pipeline, :counts)

      assert_equal 2, counts.fetch(:no_output_dropped)
      assert_equal 0, counts.fetch(:entered)
    end

    def test_nil_output_is_a_true_no_op
      Julewire.configure { it.destinations.clear }

      assert_nil Julewire.emit(message: "discarded")
      assert_empty Julewire.health.fetch(:pipeline).fetch(:destinations)
      assert_false Julewire.health.dig(:pipeline, :configured)
    end
  end
end
