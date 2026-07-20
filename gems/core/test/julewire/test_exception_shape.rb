# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestExceptionShape < Minitest::Test
    cover Julewire::Core::Serialization::ExceptionShape
    cover "Julewire::Core::Serialization::BoundedTraversal#walk_value"
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

      assert_true truncated.fetch(:cause_truncated)
      assert_equal "[Circular]", circular.fetch(:cause)
    end

    def test_exception_shape_truncates_nested_causes_at_exact_depth
      leaf = RuntimeError.new("leaf")
      middle = linked_exception("middle", leaf)
      wrapper = linked_exception("wrapper", middle)

      shaped = Julewire::Core::Serialization::ExceptionShape.call(wrapper, max_cause_depth: 1)

      refute_includes shaped, :cause_truncated
      assert_equal "middle", shaped.dig(:cause, :message)
      assert_true shaped.dig(:cause, :cause_truncated)
      refute_includes shaped.fetch(:cause), :cause
    end

    def test_exception_shape_advances_cause_depth_past_one
      leaf = RuntimeError.new("leaf")
      grandchild = linked_exception("grandchild", leaf)
      middle = linked_exception("middle", grandchild)
      wrapper = linked_exception("wrapper", middle)

      shaped = Julewire::Core::Serialization::ExceptionShape.call(wrapper, max_cause_depth: 2)

      assert_equal "middle", shaped.dig(:cause, :message)
      assert_equal "grandchild", shaped.dig(:cause, :cause, :message)
      assert_true shaped.dig(:cause, :cause, :cause_truncated)
      refute_includes shaped.dig(:cause, :cause), :cause
    end

    def test_exception_shape_omits_backtrace_when_limit_is_zero
      error = wrapped_exception
      error.set_backtrace(["wrapper.rb:1"])
      error.cause.set_backtrace(["root.rb:1"])

      shaped = Julewire::Core::Serialization::ExceptionShape.call(error, max_backtrace_lines: 0)

      refute_includes shaped, :backtrace
      refute_includes shaped.fetch(:cause), :backtrace
    end

    def test_exception_shape_does_not_read_backtrace_when_limit_is_zero
      error = RuntimeError.new("quiet")
      called = false
      error.define_singleton_method(:backtrace) do
        called = true
        ["quiet.rb:1"]
      end

      shaped = Julewire::Core::Serialization::ExceptionShape.call(error, max_backtrace_lines: 0)

      assert_false called
      refute_includes shaped, :backtrace
    end

    def test_exception_shape_limits_backtrace_lines
      error = RuntimeError.new("bounded")
      error.set_backtrace(["first.rb:1", "second.rb:2"])

      shaped = Julewire::Core::Serialization::ExceptionShape.call(error, max_backtrace_lines: 1)

      assert_equal ["first.rb:1"], shaped.fetch(:backtrace)
    end

    def test_exception_shape_duplicates_backtrace_before_limiting
      line = +"wrapper.rb:1"
      error = BacktraceError.new([line])

      shaped = Julewire::Core::Serialization::ExceptionShape.call(error)
      line.replace("mutated.rb:1")

      assert_equal ["wrapper.rb:1"], shaped.fetch(:backtrace)
      refute_same line, shaped.fetch(:backtrace).fetch(0)
    end

    def test_exception_shape_omits_unavailable_backtraces
      error = RuntimeError.new("no backtrace")
      error.define_singleton_method(:backtrace) { raise "backtrace failed" }

      shaped = Julewire::Core::Serialization::ExceptionShape.call(error)

      refute_includes shaped, :backtrace
    end

    def test_exception_shape_omits_unavailable_causes
      error = RuntimeError.new("no cause")
      error.define_singleton_method(:cause) { raise "cause failed" }

      shaped = Julewire::Core::Serialization::ExceptionShape.call(error)

      refute_includes shaped, :cause
      refute_includes shaped, :cause_truncated
    end

    def test_exception_shape_names_invalid_cause_depth_limit
      assert_raises_message(ArgumentError, "max_cause_depth must be a non-negative Integer") do
        Julewire::Core::Serialization::ExceptionShape.call(RuntimeError.new("bad"), max_cause_depth: -1)
      end
    end

    def test_exception_shape_duplicates_string_messages
      message = +"mutable"
      error = MessageError.new(message)

      shaped = Julewire::Core::Serialization::ExceptionShape.call(error)

      assert_equal "mutable", shaped.fetch(:message)
      refute_same message, shaped.fetch(:message)
    end

    def test_exception_shape_stringifies_non_string_messages
      error = MessageError.new(StringishMessage.new("object-message"))

      shaped = Julewire::Core::Serialization::ExceptionShape.call(error)

      assert_equal "object-message", shaped.fetch(:message)
    end

    def test_exception_shape_handles_unavailable_messages
      error = RuntimeError.new
      error.define_singleton_method(:message) { raise "message failed" }

      shaped = Julewire::Core::Serialization::ExceptionShape.call(error)

      assert_equal "[Unavailable]", shaped.fetch(:message)
    end

    def test_exception_shape_uses_class_string_for_anonymous_exception_classes
      error_class = Class.new(StandardError)
      error = error_class.new("anonymous")

      shaped = Julewire::Core::Serialization::ExceptionShape.call(error)

      assert_equal error_class.to_s, shaped.fetch(:class)
    end

    def test_exception_shape_uses_generic_class_when_class_lookup_fails
      error = RuntimeError.new("lying")
      error.define_singleton_method(:class) { raise "class failed" }

      shaped = Julewire::Core::Serialization::ExceptionShape.call(error)

      assert_equal "Exception", shaped.fetch(:class)
      assert_equal "lying", shaped.fetch(:message)
    end

    def test_exception_shape_returns_non_exceptions_unchanged
      value = Object.new

      assert_same value, Julewire::Core::Serialization::ExceptionShape.call(value)
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

    def linked_exception(message, cause)
      RuntimeError.new(message).tap do |error|
        error.define_singleton_method(:cause) { cause }
      end
    end

    class MessageError < StandardError
      def initialize(message)
        @message = message
        super()
      end

      attr_reader :message
    end

    class StringishMessage
      def initialize(value)
        @value = value
      end

      def to_s = @value
    end

    class BacktraceError < StandardError
      def initialize(backtrace)
        @backtrace = backtrace
        super("backtrace")
      end

      attr_reader :backtrace
    end
  end
end
