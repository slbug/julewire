# frozen_string_literal: true

require "test_helper"
require "json"
require "stringio"

module Julewire
  class TestOutputAndLevel < Minitest::Test
    def test_config_level_drops_records_below_threshold
      output = StringIO.new

      Julewire.configure do |config|
        config.level = :warn
        configure_destination(config, output: output)
      end

      Julewire.emit(severity: :debug, message: "debug")
      Julewire.emit(severity: :info, message: "info")
      Julewire.emit(severity: :warn, message: "warn")
      Julewire.emit(severity: :error, message: "error")

      severities = records_from(output).map { it.fetch("severity") }

      assert_equal %w[warn error], severities
    end

    def test_below_threshold_explicit_severity_drops_before_context_lookup
      output = StringIO.new

      Julewire.configure do |config|
        config.level = :info
        configure_destination(config, output: output)
      end

      with_context_store_probe do
        assert_nil Julewire.emit(severity: :debug, message: "debug")
      end

      assert_empty output.string
    end

    def test_below_threshold_implicit_info_drops_before_context_lookup
      output = StringIO.new

      Julewire.configure do |config|
        config.level = :warn
        configure_destination(config, output: output)
      end

      with_context_store_probe do
        assert_nil Julewire.emit(message: "implicit info")
      end

      assert_empty output.string
    end

    def test_config_level_accepts_strings
      output = StringIO.new

      Julewire.configure do |config|
        config.level = "ERROR"
        configure_destination(config, output: output)
      end

      Julewire.emit(severity: :WARN, message: "warn")
      Julewire.emit(severity: "ERROR", message: "error")

      record = JSON.parse(output.string)

      assert_equal "error", record.fetch("severity")
    end

    def test_config_level_accepts_logger_severity_integers
      output = StringIO.new

      Julewire.configure do |config|
        config.level = 2
        configure_destination(config, output: output)
      end

      Julewire.emit(severity: 1, message: "info")
      Julewire.emit(severity: 2, message: "warn")

      record = JSON.parse(output.string)

      assert_equal "warn", record.fetch("severity")
    end

    def test_invalid_config_level_does_not_replace_active_configuration_or_pipeline
      output = StringIO.new
      old_config = Julewire.configure do |config|
        configure_destination(config, output: output)
      end

      error = assert_raises(ArgumentError) do
        Julewire.configure do |config|
          config.level = :unsupported
          configure_destination(config, output: StringIO.new)
        end
      end

      assert_match "unsupported severity", error.message
      assert_same old_config, Julewire.config

      Julewire.emit(message: "still active")

      assert_includes output.string, "still active"
    end

    def test_invalid_record_severity_defaults_to_info
      output = StringIO.new

      Julewire.configure do |config|
        configure_destination(config, output: output)
      end

      capture_io do
        Julewire.emit(severity: :unsupported, message: "bad severity")
      end

      record = JSON.parse(output.string)

      assert_equal "log", record.fetch("event")
      assert_equal "info", record.fetch("severity")
      assert_equal "bad severity", record.fetch("message")
    end

    def test_invalid_record_severity_warns_once_when_record_is_emitted
      output = StringIO.new

      Julewire.configure do |config|
        config.level = :debug
        configure_destination(config, output: output)
      end

      _stdout, stderr = capture_io do
        Julewire.emit(severity: Object.new, message: "bad severity")
      end

      assert_equal 1, stderr.scan("unsupported record severity").length
      assert_equal 1, Julewire.health.dig(:counts, :invalid_record_severities)
      assert_equal "bad severity", JSON.parse(output.string).fetch("message")
    end

    def test_invalid_record_severity_warns_once_when_record_is_dropped_by_level
      output = StringIO.new

      Julewire.configure do |config|
        config.level = :warn
        configure_destination(config, output: output)
      end

      _stdout, stderr = capture_io do
        Julewire.emit(severity: Object.new, message: "bad severity")
      end

      assert_equal 1, stderr.scan("unsupported record severity").length
      assert_equal 1, Julewire.health.dig(:counts, :invalid_record_severities)
      assert_empty output.string
    end

    def test_logger_field_is_preserved
      output = StringIO.new

      Julewire.configure do |config|
        configure_destination(config, output: output)
      end

      Julewire.emit(logger: "AppLogger", message: "booted")

      record = JSON.parse(output.string)

      assert_equal "AppLogger", record.fetch("logger")
    end

    private

    def records_from(output)
      output.string.lines.map { JSON.parse(it) }
    end

    def with_context_store_probe(&)
      with_overridden_singleton_method(
        Julewire::Core::ContextStore,
        :current,
        proc { raise "context store touched" },
        &
      )
    end
  end
end
