# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestRuntimeState < Minitest::Test
    cover Julewire::Core::RuntimeState

    def test_default_builds_an_open_initial_generation
      state = Julewire::Core::RuntimeState.default

      assert_instance_of Julewire::Core::Configuration, state.configuration
      assert_predicate state.configuration, :frozen?
      assert_instance_of Julewire::Core::Processing::Pipeline, state.pipeline
      assert_false state.pipeline_closed
      assert_equal 0, state.pipeline_generation
    end

    def test_closed_preserves_runtime_components_and_marks_pipeline_closed
      state = Julewire::Core::RuntimeState.default

      closed = state.closed

      assert_same state.configuration, closed.configuration
      assert_same state.pipeline, closed.pipeline
      assert_false state.pipeline_closed
      assert_true closed.pipeline_closed
      assert_equal state.pipeline_generation, closed.pipeline_generation
    end

    def test_next_generation_installs_components_and_reopens_pipeline
      state = Julewire::Core::RuntimeState.default.closed
      configuration = Julewire::Core::Configuration.new.snapshot
      pipeline = configuration.build_pipeline

      next_state = state.next_generation(configuration: configuration, pipeline: pipeline)
      following_state = next_state.next_generation(configuration: configuration, pipeline: pipeline)

      assert_same configuration, next_state.configuration
      assert_same pipeline, next_state.pipeline
      assert_false next_state.pipeline_closed
      assert_equal state.pipeline_generation + 1, next_state.pipeline_generation
      assert_equal next_state.pipeline_generation + 1, following_state.pipeline_generation
    end
  end
end
