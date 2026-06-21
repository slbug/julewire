# frozen_string_literal: true

require "test_helper"
require_relative "../dummy/config/environment"

module Julewire
  class TestRailsErrorStack < Minitest::Test
    def setup
      super
      Julewire::Rails::Railtie.install_subscribers(::Rails.application.config.julewire_rails)
    end

    def test_rails_error_handle_reports_and_swallows
      output = configure_output

      result = ::Rails.error.handle(context: { section: "handle" }, fallback: -> { "fallback" }) do
        raise "handled"
      end

      record = error_record(output)

      assert_equal "fallback", result
      assert_error_record record, severity: "warn", handled: true, section: "handle"
    end

    def test_rails_error_record_reports_and_reraises
      output = configure_output

      assert_raises(RuntimeError) do
        ::Rails.error.record(context: { section: "record" }) do
          raise "recorded"
        end
      end

      assert_error_record error_record(output), severity: "error", handled: false, section: "record"
    end

    def test_rails_error_report_emits_error_record
      output = configure_output

      ::Rails.error.report(
        RuntimeError.new("reported"),
        handled: true,
        severity: :info,
        context: { section: "report" },
        source: "application.test"
      )

      record = error_record(output)

      assert_error_record record, severity: "info", handled: true, section: "report"
      assert_equal "application.test", record.dig("attributes", "rails", "source")
    end

    def test_rails_error_unexpected_reports_when_debug_mode_is_disabled
      output = configure_output
      previous_debug_mode = ::Rails.error.debug_mode
      ::Rails.error.debug_mode = false

      ::Rails.error.unexpected("unexpected", context: { section: "unexpected" })

      assert_error_record error_record(output), severity: "warn", handled: true, section: "unexpected"
    ensure
      ::Rails.error.debug_mode = previous_debug_mode if defined?(previous_debug_mode)
    end

    private

    def error_record(output)
      record = parse_records(output).find { it["event"] == "rails.error" }
      return record if record

      flunk("expected rails.error record in #{output.string}")
    end

    def assert_error_record(record, severity:, handled:, section:)
      assert_equal severity, record.fetch("severity")
      assert_equal "rails.error", record.fetch("event")
      assert_equal "Rails.error", record.fetch("logger")
      assert_equal handled, record.dig("attributes", "rails", "handled")
      assert_equal section, record.dig("context", "section")
      assert_equal "RuntimeError", record.dig("error", "class")
    end
  end
end
