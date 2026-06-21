# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestRactorRuntimeValidation < Minitest::Test
    cover Julewire::Ractor::Bridge::RuntimeValidation

    def test_validate_accepts_bridge_compatible_runtime
      runtime = Object.new
      runtime.define_singleton_method(:emit_envelope) { nil }
      runtime.define_singleton_method(:emit_summary_record) { nil }
      runtime.define_singleton_method(:flush) { nil }

      assert_nil Julewire::Ractor::Bridge::RuntimeValidation.validate!(runtime)
    end

    def test_validate_rejects_runtime_with_missing_methods
      error = assert_raises(ArgumentError) do
        Julewire::Ractor::Bridge::RuntimeValidation.validate!(Object.new)
      end

      assert_includes error.message, "bridge-compatible runtime"
      assert_includes error.message, "emit_envelope"
      assert_includes error.message, "emit_summary_record"
      assert_includes error.message, "flush"
    end

    def test_validate_reports_only_missing_methods
      runtime = Object.new
      runtime.define_singleton_method(:emit_envelope) { nil }
      runtime.define_singleton_method(:flush) { nil }

      error = assert_raises(ArgumentError) do
        Julewire::Ractor::Bridge::RuntimeValidation.validate!(runtime)
      end

      assert_includes error.message, "emit_summary_record"
      refute_includes error.message, "emit_envelope,"
      refute_includes error.message, "flush"
    end
  end
end
