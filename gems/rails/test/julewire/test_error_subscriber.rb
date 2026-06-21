# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestErrorSubscriber < Minitest::Test
    cover Julewire::Rails::Subscribers::Error

    def test_error_subscriber_emits_rails_error_reports
      output = configure_output
      subscriber = Julewire::Rails::Subscribers::Error.new

      subscriber.report(
        RuntimeError.new("boom"),
        handled: true,
        severity: :warning,
        context: { request_id: "req-1" },
        source: "application.test"
      )

      record = parse_records(output).fetch(0)

      assert_equal "warn", record.fetch("severity")
      assert_equal "rails.error", record.fetch("event")
      assert_equal "Rails.error", record.fetch("logger")
      assert_equal "rails", record.fetch("source")
      assert_equal "req-1", record.dig("context", "request_id")
      assert record.dig("attributes", "rails", "handled")
      assert_equal "application.test", record.dig("attributes", "rails", "source")
      assert_equal "RuntimeError", record.dig("error", "class")
      assert_julewire_record_source_contract(
        records: [record],
        event: "rails.error",
        source: "rails",
        logger: "Rails.error",
        kind: "point"
      )
    end

    def test_error_subscriber_error_field_uses_core_exception_shape
      output = configure_output
      subscriber = Julewire::Rails::Subscribers::Error.new

      report_error(subscriber, wrapped_exception)

      record = parse_records(output).fetch(0)

      assert_equal "wrapper", record.dig("error", "message")
      assert_equal "root", record.dig("error", "cause", "message")
    end

    def test_error_subscriber_respects_disabled_configuration
      output = configure_output
      configuration = Julewire::Rails::Configuration.new
      configuration.error_reports = false
      subscriber = Julewire::Rails::Subscribers::Error.new(configuration)

      report_error(subscriber)

      assert_empty parse_records(output)
    end

    def test_error_subscriber_skips_request_owned_dispatch_reports
      output = configure_output
      subscriber = Julewire::Rails::Subscribers::Error.new
      error = RuntimeError.new("owned")

      Julewire::Rails::RequestErrorOwnership.mark(error)
      subscriber.report(
        error,
        handled: false,
        severity: :error,
        context: { request_id: "req-1" },
        source: "application.action_dispatch"
      )

      assert_empty parse_records(output)
    ensure
      Julewire::Rails::RequestErrorOwnership.clear
    end

    def test_error_subscriber_keeps_unowned_dispatch_reports
      output = configure_output
      subscriber = Julewire::Rails::Subscribers::Error.new

      report_error(
        subscriber,
        RuntimeError.new("outer"),
        context: { request_id: "req-1" },
        source: "application.action_dispatch"
      )

      record = parse_records(output).fetch(0)

      assert_equal "rails.error", record.fetch("event")
      assert_equal "outer", record.dig("error", "message")
    end

    def test_error_subscriber_keeps_handled_reports_for_marked_errors
      output = configure_output
      subscriber = Julewire::Rails::Subscribers::Error.new
      error = RuntimeError.new("handled")

      Julewire::Rails::RequestErrorOwnership.mark(error)
      subscriber.report(
        error,
        handled: true,
        severity: :error,
        context: { request_id: "req-1" },
        source: "application.action_dispatch"
      )

      record = parse_records(output).fetch(0)

      assert_equal "rails.error", record.fetch("event")
      assert_equal "handled", record.dig("error", "message")
    ensure
      Julewire::Rails::RequestErrorOwnership.clear
    end

    def test_error_subscriber_keeps_automatic_rescued_dispatch_reports
      output = configure_output
      subscriber = Julewire::Rails::Subscribers::Error.new
      exception_class = define_rescued_exception("JulewireAutoDispatchRescuedError", :unprocessable_content)

      report_error(
        subscriber,
        exception_class.new("bad token"),
        context: { request_id: "req-1" },
        source: "application.action_dispatch"
      )

      record = parse_records(output).fetch(0)

      assert_equal "rails.error", record.fetch("event")
      assert_equal "application.action_dispatch", record.dig("attributes", "rails", "source")
      assert_equal "JulewireAutoDispatchRescuedError", record.dig("error", "class")
    ensure
      remove_rescued_exception("JulewireAutoDispatchRescuedError")
    end

    def test_error_subscriber_keeps_manual_reports_for_rescue_response_exceptions
      output = configure_output
      subscriber = Julewire::Rails::Subscribers::Error.new
      exception_class = define_rescued_exception("JulewireManualRescuedError", :unprocessable_content)

      report_error(subscriber, exception_class.new("bad token"), context: { request_id: "req-1" })

      record = parse_records(output).fetch(0)

      assert_equal "rails.error", record.fetch("event")
      assert_equal "JulewireManualRescuedError", record.dig("error", "class")
    ensure
      remove_rescued_exception("JulewireManualRescuedError")
    end

    def test_error_subscriber_handles_edge_inputs_and_install_idempotence
      output = configure_output
      subscriber = Julewire::Rails::Subscribers::Error.new
      severity = Object.new
      severity.define_singleton_method(:to_sym) { raise "bad severity" }

      report_error(subscriber, severity: severity, context: "bad")

      record = parse_records(output).fetch(0)

      assert_equal "info", record.fetch("severity")
      refute record.key?("context")
      refute record.dig("attributes", "rails", "handled")

      next_configuration = Julewire::Rails::Configuration.new
      next_configuration.error_reports = false

      Julewire::Rails::Subscribers::Error.reset!
      installed = Julewire::Rails::Subscribers::Error.install!(Julewire::Rails::Configuration.new)
      reinstalled = Julewire::Rails::Subscribers::Error.install!(next_configuration)

      assert installed
      assert_nil reinstalled
      refute_predicate Julewire::Rails::Subscribers::Error, :installed?
    ensure
      Julewire::Rails::Subscribers::Error.reset!
    end

    def test_error_subscriber_records_adapter_failures
      subscriber = Julewire::Rails::Subscribers::Error.new
      bad_context = Object.new
      bad_context.define_singleton_method(:is_a?) { |_class| raise "bad context" }

      _health, integration = assert_julewire_integration_failure_contract(
        integration: :rails,
        component: :error_subscriber,
        exercise: lambda do
          subscriber.report(
            RuntimeError.new("boom"),
            handled: true,
            severity: :error,
            context: bad_context,
            source: "application.test"
          )
        end
      )

      assert_equal :report, integration.dig(:last_failure, :action)
      assert_equal "RuntimeError", integration.dig(:last_failure, :class)
    end

    def test_error_subscriber_normalizes_controller_context_objects
      output = configure_output
      subscriber = Julewire::Rails::Subscribers::Error.new
      controller = Class.new do
        class << self
          def name = "ExampleController"
        end
      end.new

      report_error(subscriber, context: { controller: controller, action: :show })

      record = parse_records(output).fetch(0)

      assert_equal "ExampleController", record.dig("context", "controller")
      assert_equal "show", record.dig("context", "action")
    end

    def test_error_subscriber_keeps_string_controller_context
      output = configure_output
      subscriber = Julewire::Rails::Subscribers::Error.new

      report_error(subscriber, context: { controller: "StringController" })

      assert_equal "StringController", parse_records(output).fetch(0).dig("context", "controller")
    end

    private

    def report_error(subscriber, error = RuntimeError.new("boom"), **)
      subscriber.report(
        error,
        handled: false,
        severity: :error,
        context: {},
        source: "application.test",
        **
      )
    end

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
