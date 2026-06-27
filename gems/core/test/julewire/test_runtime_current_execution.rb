# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestRuntimeCurrentExecution < Minitest::Test
    cover "Julewire::Core::Runtime#current_execution?"

    def test_current_execution_tracks_the_real_execution_lifecycle
      runtime = Julewire::Core::RuntimeLocator.current

      refute_predicate runtime, :current_execution?

      runtime.with_execution(type: :request, emit_summary: false) do
        assert_predicate runtime, :current_execution?
      end

      refute_predicate runtime, :current_execution?
    end
  end

  class TestFacadeCurrentExecution < Minitest::Test
    cover "Julewire::Core::FacadeMethods#current_execution?"

    def test_current_execution_tracks_the_real_execution_lifecycle
      refute_predicate Julewire, :current_execution?

      Julewire.with_execution(type: :request, emit_summary: false) do
        assert_predicate Julewire, :current_execution?
      end

      refute_predicate Julewire, :current_execution?
    end
  end
end
