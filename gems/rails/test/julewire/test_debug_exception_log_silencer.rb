# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestDebugExceptionLogSilencer < Minitest::Test
    Wrapper = Data.define(:exception, :unwrapped_exception) do
      def rescue_response? = false
    end

    def test_does_not_suppress_without_configuration
      refute_suppressed(nil, wrapper)
    end

    def test_suppresses_unrescued_exception_logs_by_default
      assert_suppressed(Julewire::Rails::Configuration.new, wrapper)
    end

    def test_suppresses_when_request_summary_owns_errors_even_without_error_reports
      configuration = Julewire::Rails::Configuration.new
      configuration.error_reports = false

      assert_suppressed(configuration, wrapper)
    end

    def test_suppresses_when_rails_error_owns_errors_without_request_summary
      configuration = Julewire::Rails::Configuration.new
      configuration.request_summary = false

      assert_suppressed(configuration, wrapper)
    end

    def test_does_not_suppress_auto_when_no_julewire_error_owner_is_enabled
      configuration = Julewire::Rails::Configuration.new
      configuration.error_reports = false
      configuration.request_summary = false

      refute_suppressed(configuration, wrapper)
    end

    def test_does_not_suppress_auto_when_logger_is_not_julewire
      configuration = Julewire::Rails::Configuration.new
      configuration.logger = false

      refute_suppressed(configuration, wrapper)
    end

    def test_allows_explicit_raw_reported_exception_logs
      configuration = Julewire::Rails::Configuration.new
      configuration.reported_exception_logs = true

      refute_suppressed(configuration, wrapper)
    end

    def test_allows_explicit_suppression
      configuration = Julewire::Rails::Configuration.new
      configuration.reported_exception_logs = false
      configuration.error_reports = false
      configuration.request_summary = false
      configuration.logger = false

      assert_suppressed(configuration, wrapper)
    end

    def test_records_suppression_failures
      configuration = Object.new
      configuration.define_singleton_method(:reported_exception_logs) { raise "bad configuration" }

      with_silencer_configuration(configuration) do
        _health, integration = assert_julewire_integration_failure_contract(
          integration: :rails,
          component: :debug_exception_log_silencer,
          exercise: -> { Julewire::Rails::DebugExceptionLogSilencer.suppress?(nil, wrapper) }
        )

        assert_equal :suppress?, integration.dig(:last_failure, :action)
        assert_equal "RuntimeError", integration.dig(:last_failure, :class)
      end
    end

    private

    def wrapper
      exception = RuntimeError.new("boom")
      Wrapper.new(exception, exception)
    end

    def assert_suppressed(configuration, wrapper)
      with_silencer_configuration(configuration) do
        assert Julewire::Rails::DebugExceptionLogSilencer.suppress?(nil, wrapper)
      end
    end

    def refute_suppressed(configuration, wrapper)
      with_silencer_configuration(configuration) do
        refute Julewire::Rails::DebugExceptionLogSilencer.suppress?(nil, wrapper)
      end
    end

    def with_silencer_configuration(configuration)
      previous_configuration = Julewire::Rails::DebugExceptionLogSilencer.instance_variable_get(:@configuration)
      Julewire::Rails::DebugExceptionLogSilencer.install!(configuration)
      yield
    ensure
      Julewire::Rails::DebugExceptionLogSilencer.instance_variable_set(:@configuration, previous_configuration)
    end
  end
end
