# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestExceptionShape < Minitest::Test
    cover Julewire::Core::Serialization::ExceptionShape
    cover Julewire::Core::Serialization::Serializer

    def test_exception_shape_and_serializer_include_bounded_causes
      error = wrapped_exception

      shaped = Julewire::Core::Serialization::ExceptionShape.call(error)
      serialized = Julewire::Core::Serialization::Serializer.call(error)

      assert_equal "RuntimeError", shaped.fetch(:class)
      assert_equal "wrapper", shaped.fetch(:message)
      assert_equal "RuntimeError", shaped.dig(:cause, :class)
      assert_equal "root", shaped.dig(:cause, :message)
      assert_equal "RuntimeError", serialized.fetch("cause").fetch("class")
      assert_equal "root", serialized.fetch("cause").fetch("message")
    end

    def test_exception_shape_bounds_cause_depth_and_handles_cycles
      error = wrapped_exception
      cyclic = RuntimeError.new("cycle")
      cyclic.define_singleton_method(:cause) { self }

      truncated = Julewire::Core::Serialization::ExceptionShape.call(error, max_cause_depth: 0)
      circular = Julewire::Core::Serialization::ExceptionShape.call(cyclic)

      assert truncated.fetch(:cause_truncated)
      assert_equal "[Circular]", circular.fetch(:cause)
    end

    def test_exception_shape_omits_backtrace_when_limit_is_zero
      error = wrapped_exception
      error.set_backtrace(["wrapper.rb:1"])
      error.cause.set_backtrace(["root.rb:1"])

      shaped = Julewire::Core::Serialization::ExceptionShape.call(error, max_backtrace_lines: 0)

      refute_includes shaped, :backtrace
      refute_includes shaped.fetch(:cause), :backtrace
    end

    def test_record_draft_error_normalization_uses_exception_shape
      records = capture_julewire_records do
        Julewire.emit(error: wrapped_exception)
      end

      error = records.fetch(0).fetch(:error)

      assert_equal "wrapper", error.fetch(:message)
      assert_equal "root", error.dig(:cause, :message)
    end

    private

    def wrapped_exception
      begin
        raise "root"
      rescue StandardError
        raise "wrapper"
      end
    rescue StandardError => e
      e
    end
  end
end
