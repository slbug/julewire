# frozen_string_literal: true

require "test_helper"
require "json"
require "stringio"

module Julewire
  class TestSeverityValidation < Minitest::Test
    cover Julewire::Core::Records::Severity

    def test_severity_rank_accepts_normalized_symbols_strings_and_logger_integers
      severity = Julewire::Core::Records::Severity

      assert_equal 0, severity.rank(:debug)
      assert_equal 3, severity.rank(3)
      assert_equal :info, severity.normalize(:info)
      assert_equal :info, severity.normalize(:INFO)
    end

    def test_severity_normalizes_supported_symbols_without_allocation_path
      severity = Julewire::Core::Records::Severity

      Julewire::Core::Records::Severity::VALUES.each do |value|
        assert_equal value, severity.normalize(value)
      end
    end

    def test_severity_normalizes_case_insensitive_symbols_and_strings
      severity = Julewire::Core::Records::Severity

      assert_equal :warn, severity.normalize(:WARN)
      assert_equal :error, severity.normalize(:Error)
      assert_equal :fatal, severity.normalize("FATAL")
      assert_equal :unknown, severity.normalize("unknown")
    end

    def test_severity_normalizes_logger_integer_values
      severity = Julewire::Core::Records::Severity

      assert_equal :debug, severity.normalize(0)
      assert_equal :info, severity.normalize(1)
      assert_equal :warn, severity.normalize(2)
      assert_equal :error, severity.normalize(3)
      assert_equal :fatal, severity.normalize(4)
      assert_equal :unknown, severity.normalize(5)
    end

    def test_severity_rejects_unsupported_values
      severity = Julewire::Core::Records::Severity

      assert_unsupported_severity(:warning, ":warning")
      assert_unsupported_severity("warning", "\"warning\"")
      assert_unsupported_severity(6, "6")
      assert_unsupported_severity(nil, "nil")
      assert_unsupported_severity(false, "false")

      object = Object.new
      error = assert_raises(ArgumentError) { severity.normalize(object) }
      assert_match(/\Aunsupported severity: #<Object:/, error.message)
    end

    def test_severity_symbol_returns_unvalidated_symbol_or_nil
      severity = Julewire::Core::Records::Severity

      assert_equal :info, severity.severity_symbol(:INFO)
      assert_equal :warning, severity.severity_symbol(:WARNING)
      assert_equal :debug, severity.severity_symbol("debug")
      assert_equal :fatal, severity.severity_symbol(4)
      assert_nil severity.severity_symbol("warning")
      assert_nil severity.severity_symbol(6)
      assert_nil severity.severity_symbol(false)
    end

    def test_severity_rank_accepts_every_normalized_input_shape
      severity = Julewire::Core::Records::Severity

      assert_equal 0, severity.rank(:debug)
      assert_equal 1, severity.rank("info")
      assert_equal 2, severity.rank(:WARN)
      assert_equal 3, severity.rank(3)
      assert_equal 4, severity.rank("FATAL")
      assert_equal 5, severity.rank(:unknown)
    end

    def test_severity_rank_rejects_unsupported_values
      severity = Julewire::Core::Records::Severity

      assert_raises(ArgumentError) { severity.rank(:warning) }
      assert_raises(ArgumentError) { severity.rank("warning") }
      assert_raises(ArgumentError) { severity.rank(6) }
      assert_raises(ArgumentError) { severity.rank(nil) }
    end

    def test_false_explicit_severity_defaults_to_info
      output = StringIO.new

      Julewire.configure do |config|
        configure_destination(config, output: output)
      end

      capture_io do
        Julewire.emit(severity: false, source: "app", event: "work", message: "bad severity")
      end

      record = JSON.parse(output.string)

      assert_equal "work", record.fetch("event")
      assert_equal "info", record.fetch("severity")
      assert_equal "bad severity", record.fetch("message")
      assert_equal 1, Julewire.health.fetch(:counts).fetch(:invalid_record_severities)
    end

    def test_invalid_severity_normalizes_to_info_before_threshold
      output = StringIO.new
      Julewire.configure do |config|
        config.level = :warn
        configure_destination(config, output: output)
      end

      capture_io do
        Julewire.emit(severity: false, source: "app", event: "quiet", message: "bad severity")
      end

      assert_empty output.string
      assert_equal 1, Julewire.health.dig(:pipeline, :counts, :level_dropped)
      assert_equal 1, Julewire.health.dig(:counts, :invalid_record_severities)
    end

    def test_warning_is_not_supported_severity
      output = StringIO.new

      Julewire.configure do |config|
        configure_destination(config, output: output)
      end

      capture_io do
        Julewire.emit(severity: "warning", source: "app", event: "work", message: "warn severity")
      end

      record = JSON.parse(output.string)

      assert_equal "info", record.fetch("severity")
      assert_equal 1, Julewire.health.fetch(:counts).fetch(:invalid_record_severities)
    end

    def test_invalid_severity_counts_are_runtime_local
      default_output = StringIO.new
      audit_output = StringIO.new
      audit = Julewire.runtime(:audit)

      Julewire.configure do |config|
        configure_destination(config, output: default_output)
      end
      audit.configure do |config|
        configure_destination(config, output: audit_output)
      end

      capture_io do
        audit.emit(severity: Object.new, source: "audit", event: "work", message: "bad severity")
      end

      assert_equal 0, Julewire.health.fetch(:counts).fetch(:invalid_record_severities)
      assert_equal 1, audit.health.fetch(:counts).fetch(:invalid_record_severities)
      assert_empty default_output.string
      assert_equal "bad severity", JSON.parse(audit_output.string).fetch("message")
    end

    private

    def assert_unsupported_severity(value, inspect_output)
      error = assert_raises(ArgumentError) { Julewire::Core::Records::Severity.normalize(value) }

      assert_equal "unsupported severity: #{inspect_output}", error.message
    end
  end
end
