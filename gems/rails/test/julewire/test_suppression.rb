# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestRailsSuppression < Minitest::Test
    cover Julewire::Rails::Suppression
    def test_suppression_restores_preexisting_state
      state = ::ActiveSupport::IsolatedExecutionState
      state[Julewire::Rails::Suppression::KEY] = :outer

      assert_true Julewire::Rails::Suppression.active?
      Julewire::Rails::Suppression.suppress do
        assert_true Julewire::Rails::Suppression.active?
        assert_true state[Julewire::Rails::Suppression::KEY]
      end

      assert_equal :outer, state[Julewire::Rails::Suppression::KEY]
    ensure
      state&.delete(Julewire::Rails::Suppression::KEY)
    end

    def test_suppression_active_uses_value_not_key_presence
      state = ::ActiveSupport::IsolatedExecutionState
      state[Julewire::Rails::Suppression::KEY] = false

      assert_false Julewire::Rails::Suppression.active?
    ensure
      state&.delete(Julewire::Rails::Suppression::KEY)
    end

    def test_nested_suppression_keeps_outer_scope_active
      state = ::ActiveSupport::IsolatedExecutionState

      refute state.key?(Julewire::Rails::Suppression::KEY)
      assert_false Julewire::Rails::Suppression.active?

      Julewire::Rails::Suppression.suppress do
        Julewire::Rails::Suppression.suppress do
          assert_true Julewire::Rails::Suppression.active?
        end

        assert_true Julewire::Rails::Suppression.active?
      end

      assert_false Julewire::Rails::Suppression.active?
      refute state.key?(Julewire::Rails::Suppression::KEY)
    end

    def test_suppression_cleans_state_after_exception
      state = ::ActiveSupport::IsolatedExecutionState

      assert_raises(RuntimeError) do
        Julewire::Rails::Suppression.suppress do
          assert_true Julewire::Rails::Suppression.active?
          raise "boom"
        end
      end

      assert_false Julewire::Rails::Suppression.active?
      refute state.key?(Julewire::Rails::Suppression::KEY)
    end

    def test_suppression_uses_top_level_active_support_constant
      with_shadowed_active_support_execution_state do
        Julewire::Rails::Suppression.suppress do
          assert_true Julewire::Rails::Suppression.active?
        end
        refute ::ActiveSupport::IsolatedExecutionState.key?(Julewire::Rails::Suppression::KEY)

        ::ActiveSupport::IsolatedExecutionState[Julewire::Rails::Suppression::KEY] = :outer

        Julewire::Rails::Suppression.suppress do
          assert_true Julewire::Rails::Suppression.active?
        end

        assert_equal :outer, ::ActiveSupport::IsolatedExecutionState[Julewire::Rails::Suppression::KEY]
      end
    ensure
      ::ActiveSupport::IsolatedExecutionState.delete(Julewire::Rails::Suppression::KEY)
    end
  end
end
