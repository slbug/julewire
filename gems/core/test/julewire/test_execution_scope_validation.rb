# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestExecutionScopeValidation < Minitest::Test
    def test_with_execution_rejects_missing_type
      error = assert_raises(ArgumentError) do
        Julewire.with_execution(type: nil, emit_summary: false) { flunk "should not run" }
      end

      assert_equal "execution type is required", error.message
    end

    def test_execution_options_validate_public_shapes
      assert_raises(ArgumentError) { Julewire.with_execution(type: :job, fields: "trace-1") { :unused } }
      assert_raises(ArgumentError) { Julewire.with_execution(type: :job, summary_event: "") { :unused } }
    end

    def test_execution_options_reject_unknown_public_fields
      error = assert_raises(ArgumentError) do
        Julewire.with_execution(type: :job, attributes_owned: true) { :unused }
      end

      assert_equal "unknown execution options: attributes_owned", error.message
    end

    def test_runtime_execution_options_require_type
      runtime = Julewire::Core::Runtime.new

      assert_raises(ArgumentError) { runtime.with_execution(emit_summary: false) { :unused } }
    end
  end
end
