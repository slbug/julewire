# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestRequestErrorOwnership < Minitest::Test
    cover Julewire::Rails::RequestErrorOwnership
    cover "Julewire::Rails::RequestErrorOwnership.clear"

    def test_request_error_ownership_uses_exact_exception_identity
      error_class = Class.new(StandardError) do
        def eql?(other) = other.is_a?(self.class)
        def hash = 1
      end
      first = error_class.new("first")
      second = error_class.new("second")

      Julewire::Rails::RequestErrorOwnership.mark(first)

      assert_false Julewire::Rails::RequestErrorOwnership.consume?(second)
      assert_true Julewire::Rails::RequestErrorOwnership.consume?(first)
    ensure
      Julewire::Rails::RequestErrorOwnership.clear
    end

    def test_request_error_ownership_walks_equal_cause_objects_by_identity
      error_class = Class.new(StandardError) do
        attr_writer :custom_cause

        def cause = @custom_cause
        def eql?(other) = other.is_a?(self.class)
        def hash = 1
      end
      root = error_class.new("root")
      wrapper = error_class.new("wrapper")
      wrapper.custom_cause = root

      Julewire::Rails::RequestErrorOwnership.mark(wrapper)

      assert_true Julewire::Rails::RequestErrorOwnership.consume?(root)
      assert_true Julewire::Rails::RequestErrorOwnership.consume?(wrapper)
      assert_false Julewire::Rails::RequestErrorOwnership.consume?(root)
    ensure
      Julewire::Rails::RequestErrorOwnership.clear
    end

    def test_request_error_ownership_stops_on_cyclic_cause_chain
      error_class = Class.new(StandardError) do
        attr_writer :custom_cause

        def cause
          @cause_calls = @cause_calls.to_i + 1
          raise "cycle guard failed" if @cause_calls > 1

          @custom_cause
        end
      end
      error = error_class.new("cycle")
      error.custom_cause = error

      Julewire::Rails::RequestErrorOwnership.mark(error)

      assert_true Julewire::Rails::RequestErrorOwnership.consume?(error)
    ensure
      Julewire::Rails::RequestErrorOwnership.clear
    end

    def test_request_error_ownership_returns_false_for_unowned_error
      assert_false Julewire::Rails::RequestErrorOwnership.consume?(RuntimeError.new("unowned"))
    ensure
      Julewire::Rails::RequestErrorOwnership.clear
    end

    def test_request_error_ownership_marks_wrapper_and_cause_chain
      root = RuntimeError.new("root")
      wrapper = nil
      begin
        raise root
      rescue RuntimeError
        begin
          raise "wrapper"
        rescue RuntimeError => e
          wrapper = e
        end
      end

      Julewire::Rails::RequestErrorOwnership.mark(wrapper)

      assert_true Julewire::Rails::RequestErrorOwnership.consume?(root)
      assert_true Julewire::Rails::RequestErrorOwnership.consume?(wrapper)
      assert_false Julewire::Rails::RequestErrorOwnership.consume?(root)
    ensure
      Julewire::Rails::RequestErrorOwnership.clear
    end

    def test_request_error_ownership_reuses_error_map
      first = RuntimeError.new("first")
      second = RuntimeError.new("second")

      Julewire::Rails::RequestErrorOwnership.mark(first)
      Julewire::Rails::RequestErrorOwnership.mark(second)

      assert_true Julewire::Rails::RequestErrorOwnership.consume?(first)
      assert_true Julewire::Rails::RequestErrorOwnership.consume?(second)
      assert_false Julewire::Rails::RequestErrorOwnership.consume?(first)
    ensure
      Julewire::Rails::RequestErrorOwnership.clear
    end

    def test_request_error_ownership_uses_top_level_active_support_state
      error = RuntimeError.new("owned")
      shadow = Module.new do
        def self.const_missing(_name)
          raise "shadow ActiveSupport namespace used"
        end
      end

      with_temporary_constant(Julewire::Rails, :ActiveSupport, shadow) do
        Julewire::Rails::RequestErrorOwnership.mark(error)

        assert_true Julewire::Rails::RequestErrorOwnership.consume?(error)
        Julewire::Rails::RequestErrorOwnership.clear
      end
    ensure
      Julewire::Rails::RequestErrorOwnership.clear
    end
  end
end
