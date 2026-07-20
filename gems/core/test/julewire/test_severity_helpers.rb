# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestSeverityHelpers < Minitest::Test
    cover "Julewire.debug"
    cover "Julewire.info"
    cover "Julewire.warn"
    cover "Julewire.error"
    cover "Julewire.fatal"
    cover "Julewire.unknown"
    cover "Julewire::Core::FacadeMethods#debug"
    cover "Julewire::Core::FacadeMethods#error"
    cover "Julewire::Core::FacadeMethods#fatal"
    cover "Julewire::Core::FacadeMethods#info"
    cover "Julewire::Core::FacadeMethods#unknown"
    cover "Julewire::Core::FacadeMethods#warn"
    cover "Julewire::Core::FacadePrivateMethods#emit_with_severity"
    RuntimeCall = Data.define(:record, :block)

    class RuntimeSpy
      attr_reader :calls

      def initialize
        @calls = []
      end

      def emit(record = Core::UNSET, **fields, &block)
        raise "unexpected keyword fields" unless fields.empty?

        @calls << RuntimeCall.new(record, block)
        :emitted
      end
    end

    def test_severity_helpers_emit_with_lazy_block_support
      records = configure_record_capture(level: :debug)

      Julewire.debug { { message: "debug message" } }
      Julewire.warn("warn message")
      Julewire.error(message: "error message")

      assert_equal(%i[debug warn error], records.map { it.fetch(:severity) })
      assert_equal(
        ["debug message", "warn message", "error message"],
        records.map { it.fetch(:message) }
      )
    end

    def test_scalar_severity_helper_does_not_allow_field_severity_override
      records = configure_record_capture(level: :debug)

      Julewire.warn("warn message", severity: :fatal)

      assert_equal :warn, records.fetch(0).fetch(:severity)
      assert_equal "warn message", records.fetch(0).fetch(:message)
    end

    def test_kwargs_only_severity_helper_does_not_allow_field_severity_override
      records = configure_record_capture(level: :debug)

      Julewire.warn(message: "warn message", severity: :debug)

      assert_equal :warn, records.fetch(0).fetch(:severity)
      assert_equal "warn message", records.fetch(0).fetch(:message)
    end

    def test_string_key_kwargs_severity_helper_does_not_allow_field_severity_override
      records = configure_record_capture(level: :debug)

      Julewire.warn(**{ "severity" => "debug", message: "warn message" })

      assert_equal :warn, records.fetch(0).fetch(:severity)
      assert_equal "warn message", records.fetch(0).fetch(:message)
    end

    def test_kwargs_only_severity_helper_sends_eager_shape_to_runtime
      runtime = RuntimeSpy.new
      facade = facade_with_runtime(runtime)

      result = facade.warn(**{ message: "keyword message", "severity" => :fatal })
      call = runtime.calls.fetch(0)

      assert_equal :emitted, result
      assert_nil call.block
      assert_equal({ message: "keyword message", severity: :warn }, call.record)
      refute_includes call.record, "severity"
    end

    def test_empty_severity_helper_sends_severity_only_eager_shape_to_runtime
      runtime = RuntimeSpy.new
      facade = facade_with_runtime(runtime)

      facade.warn
      call = runtime.calls.fetch(0)

      assert_nil call.block
      assert_equal({ severity: :warn }, call.record)
    end

    def test_unknown_helper_sends_unknown_severity_without_record
      runtime = RuntimeSpy.new
      facade = facade_with_runtime(runtime)

      result = facade.unknown
      call = runtime.calls.fetch(0)

      assert_equal :emitted, result
      assert_nil call.block
      assert_equal({ severity: :unknown }, call.record)
    end

    def test_unknown_helper_preserves_record_and_keyword_fields
      runtime = RuntimeSpy.new
      facade = facade_with_runtime(runtime)

      facade.unknown("mystery", attempt: 3)
      call = runtime.calls.fetch(0)

      assert_nil call.block
      assert_equal({ message: "mystery", attempt: 3, severity: :unknown }, call.record)
    end

    def test_unknown_helper_keeps_lazy_block
      runtime = RuntimeSpy.new
      facade = facade_with_runtime(runtime)

      facade.unknown { { message: "lazy mystery" } }
      call = runtime.calls.fetch(0)

      assert_equal({ severity: :unknown }, call.record.to_h)
      assert_equal({ message: "lazy mystery" }, call.block.call)
    end

    def test_scalar_severity_helper_sends_eager_shape_to_runtime
      runtime = RuntimeSpy.new
      facade = facade_with_runtime(runtime)
      scalar = Object.new
      scalar.define_singleton_method(:to_s) { "scalar message" }

      facade.warn(scalar, **{ "severity" => :fatal, attempt: 3 })
      call = runtime.calls.fetch(0)

      assert_nil call.block
      assert_equal(
        { message: "scalar message", attempt: 3, severity: :warn },
        call.record
      )
      refute_includes call.record, "severity"
    end

    def test_scalar_severity_helper_without_fields_stringifies_message
      runtime = RuntimeSpy.new
      facade = facade_with_runtime(runtime)
      scalar = Object.new
      scalar.define_singleton_method(:to_s) { "scalar message" }

      facade.warn(scalar)
      call = runtime.calls.fetch(0)

      assert_nil call.block
      assert_equal({ message: "scalar message", severity: :warn }, call.record)
    end

    def test_hash_severity_helper_uses_lazy_severity_wrapper_without_mutating_input
      runtime = RuntimeSpy.new
      facade = facade_with_runtime(runtime)
      input = Class.new(Hash).new.merge!(message: "hash message", severity: :fatal)

      facade.warn(input)
      call = runtime.calls.fetch(0)

      assert_nil call.block
      refute_kind_of Hash, call.record
      assert_equal({ message: "hash message", severity: :warn }, call.record.to_h)
      assert_equal :fatal, input.fetch(:severity)
    end

    def test_scalar_severity_helper_with_block_keeps_lazy_wrapper_and_block
      runtime = RuntimeSpy.new
      facade = facade_with_runtime(runtime)

      facade.warn("eager message") { { message: "lazy message" } }
      call = runtime.calls.fetch(0)

      refute_kind_of Hash, call.record
      assert_equal({ message: "eager message", severity: :warn }, call.record.to_h)
      assert_equal({ message: "lazy message" }, call.block.call)
    end

    def test_severity_helper_lazy_block_is_not_evaluated_below_threshold
      records = configure_record_capture(level: :info)
      called = false

      Julewire.debug do
        called = true
        { severity: :fatal, message: "debug message" }
      end

      assert_false called
      assert_empty records
    end

    def test_severity_helper_drops_below_threshold_without_copying_eager_input
      records = configure_record_capture(level: :info)
      input = Class.new(Hash) do
        def each
          raise "eager input copied"
        end
      end.new
      input[:payload] = { token: "secret" }

      Julewire.debug(input)

      assert_empty records
    end

    def test_severity_helper_lazy_block_cannot_override_helper_severity
      records = configure_record_capture(level: :debug)

      Julewire.warn { { severity: :fatal, message: "warn message" } }

      assert_equal :warn, records.fetch(0).fetch(:severity)
      assert_equal "warn message", records.fetch(0).fetch(:message)
    end

    private

    def facade_with_runtime(runtime)
      Object.new.tap do |facade|
        facade.extend Core::FacadeMethods
        facade.define_singleton_method(:runtime) { runtime }
      end
    end
  end
end
