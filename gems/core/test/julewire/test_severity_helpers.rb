# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestSeverityHelpers < Minitest::Test
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

    def test_severity_helper_lazy_block_is_not_evaluated_below_threshold
      records = configure_record_capture(level: :info)
      called = false

      Julewire.debug do
        called = true
        { severity: :fatal, message: "debug message" }
      end

      refute called
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
  end
end
