# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestDebugExceptionLogSilencer < Minitest::Test
    cover Julewire::Rails::DebugExceptionLogSilencer
    cover "Julewire::Rails::DebugExceptionLogSilencer::Patch"

    def test_does_not_suppress_without_configuration
      with_silencer_configuration(nil) do
        assert_false Julewire::Rails::DebugExceptionLogSilencer.suppress?
        assert_empty Julewire.health.fetch(:process_integrations)
      end
    end

    def test_suppresses_unrescued_exception_logs_by_default
      assert_suppressed(Julewire::Rails::Configuration.new)
    end

    def test_suppresses_when_request_summary_owns_errors_even_without_error_reports
      configuration = Julewire::Rails::Configuration.new
      configuration.error_reports = false

      assert_suppressed(configuration)
    end

    def test_suppresses_when_rails_error_owns_errors_without_request_summary
      configuration = Julewire::Rails::Configuration.new
      configuration.request_summary = false

      assert_suppressed(configuration)
    end

    def test_does_not_suppress_auto_when_no_julewire_error_owner_is_enabled
      configuration = Julewire::Rails::Configuration.new
      configuration.error_reports = false
      configuration.request_summary = false

      refute_suppressed(configuration)
    end

    def test_does_not_suppress_auto_when_logger_is_not_julewire
      configuration = Julewire::Rails::Configuration.new
      configuration.logger = false

      refute_suppressed(configuration)
    end

    def test_allows_explicit_raw_reported_exception_logs
      configuration = Julewire::Rails::Configuration.new
      configuration.reported_exception_logs = true

      refute_suppressed(configuration)
    end

    def test_allows_explicit_suppression
      configuration = Julewire::Rails::Configuration.new
      configuration.reported_exception_logs = false
      configuration.error_reports = false
      configuration.request_summary = false
      configuration.logger = false

      assert_suppressed(configuration)
    end

    def test_records_suppression_failures
      configuration = Object.new
      configuration.define_singleton_method(:reported_exception_logs) { raise "bad configuration" }

      with_silencer_configuration(configuration) do
        assert_nil Julewire::Rails::DebugExceptionLogSilencer.suppress?

        health = Julewire.health
        integration = health.dig(:process_integrations, :rails)

        assert_equal :degraded, health.fetch(:status)
        assert_equal :degraded, integration.fetch(:status)
        assert_equal 1, integration.dig(:counts, :failures)
        assert_equal :debug_exception_log_silencer, integration.dig(:last_failure, :component)
        assert_equal :suppress?, integration.dig(:last_failure, :action)
        assert_equal "RuntimeError", integration.dig(:last_failure, :class)
        refute_includes integration.fetch(:last_failure), :message
      end
    end

    def test_install_prepends_debug_exception_patch_and_updates_configuration
      configuration = Julewire::Rails::Configuration.new
      next_configuration = Julewire::Rails::Configuration.new
      next_configuration.reported_exception_logs = true
      previous_configuration = Julewire::Rails::DebugExceptionLogSilencer.instance_variable_get(:@configuration)
      patch = Julewire::Rails::DebugExceptionLogSilencer.const_get(:Patch, false)
      top_level_dispatch = Module.new
      top_level_exceptions = Class.new
      nested_dispatch = Module.new
      nested_exceptions = Class.new
      top_level_dispatch.const_set(:DebugExceptions, top_level_exceptions)
      nested_dispatch.const_set(:DebugExceptions, nested_exceptions)

      with_constant(Object, :ActionDispatch, top_level_dispatch) do
        with_constant(Julewire::Rails::DebugExceptionLogSilencer, :ActionDispatch, nested_dispatch) do
          Julewire::Rails::DebugExceptionLogSilencer.install!(configuration)

          assert_includes top_level_exceptions.ancestors, patch
          refute_includes nested_exceptions.ancestors, patch
          assert_true Julewire::Rails::DebugExceptionLogSilencer.suppress?

          Julewire::Rails::DebugExceptionLogSilencer.install!(next_configuration)

          assert_false Julewire::Rails::DebugExceptionLogSilencer.suppress?
        end
      end
    ensure
      Julewire::Rails::DebugExceptionLogSilencer.install!(previous_configuration)
    end

    def test_patch_delegates_or_suppresses_real_log_error_call
      calls = []
      base = Class.new do
        def initialize(observed)
          @observed = observed
        end

        def log_error(request, wrapper)
          @observed << [request, wrapper]
          :logged
        end
      end
      base.prepend(Julewire::Rails::DebugExceptionLogSilencer.const_get(:Patch, false))
      subject = base.new(calls)
      request = Object.new
      current_wrapper = Object.new
      allowed = Julewire::Rails::Configuration.new
      allowed.reported_exception_logs = true
      suppressed = Julewire::Rails::Configuration.new
      suppressed.reported_exception_logs = false

      allowed_result = with_silencer_configuration(allowed) { subject.log_error(request, current_wrapper) }
      suppressed_result = with_silencer_configuration(suppressed) { subject.log_error(request, current_wrapper) }

      assert_equal :logged, allowed_result
      assert_nil suppressed_result
      assert_equal [[request, current_wrapper]], calls
    end

    private

    def assert_suppressed(configuration)
      with_silencer_configuration(configuration) do
        assert_true Julewire::Rails::DebugExceptionLogSilencer.suppress?
      end
    end

    def refute_suppressed(configuration)
      with_silencer_configuration(configuration) do
        assert_false Julewire::Rails::DebugExceptionLogSilencer.suppress?
      end
    end

    def with_silencer_configuration(configuration)
      previous_configuration = Julewire::Rails::DebugExceptionLogSilencer.instance_variable_get(:@configuration)
      Julewire::Rails::DebugExceptionLogSilencer.install!(configuration)
      yield
    ensure
      Julewire::Rails::DebugExceptionLogSilencer.install!(previous_configuration)
    end
  end
end
