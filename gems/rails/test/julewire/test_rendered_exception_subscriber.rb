# frozen_string_literal: true

require "test_helper"
require "action_dispatch/testing/test_request"

module Julewire
  class TestRenderedExceptionSubscriber < Minitest::Test
    cover Julewire::Rails::Subscribers::RenderedException

    def test_rendered_exception_subscriber_emits_rescued_response_records
      output = configure_output
      subscriber = Julewire::Rails::Subscribers::RenderedException.new(rendered_exception_configuration)

      subscriber.call(
        debug_exception_request("/missing"),
        ActionController::RoutingError.new('No route matches [POST] "/missing"')
      )

      record = parse_records(output).fetch(0)

      assert_equal "error", record.fetch("severity")
      assert_equal "action_dispatch.rendered_exception", record.fetch("event")
      assert_equal "ActionDispatch::DebugExceptions", record.fetch("logger")
      assert_equal 404, record.dig("attributes", "rails", "status")
      assert record.dig("attributes", "rails", "rescue_response")
      assert_equal "routing_error", record.dig("attributes", "rails", "rescue_template")
      assert_equal "ActionController::RoutingError", record.dig("error", "class")
    end

    def test_rendered_exception_subscriber_leaves_unhandled_app_errors_to_rails_error
      output = configure_output
      subscriber = Julewire::Rails::Subscribers::RenderedException.new(rendered_exception_configuration)

      subscriber.call(debug_exception_request("/boom"), RuntimeError.new("boom"))

      record = parse_records(output).fetch(0)

      assert_equal "action_dispatch.rendered_exception", record.fetch("event")
      assert_equal 500, record.dig("attributes", "rails", "status")
      refute record.dig("attributes", "rails", "rescue_response")
    end

    def test_rendered_exception_subscriber_emits_custom_rescued_exceptions
      output = configure_output
      subscriber = Julewire::Rails::Subscribers::RenderedException.new(rendered_exception_configuration)
      exception_class = define_rescued_exception("JulewireReportedRenderedError", :unprocessable_content)
      exception = exception_class.new("bad token")

      subscriber.call(debug_exception_request("/csrf"), exception)

      record = parse_records(output).fetch(0)

      assert_equal "action_dispatch.rendered_exception", record.fetch("event")
      assert_equal 422, record.dig("attributes", "rails", "status")
    ensure
      remove_rescued_exception("JulewireReportedRenderedError")
    end

    def test_rendered_exception_subscriber_skips_when_rails_will_not_show_exception
      output = configure_output
      subscriber = Julewire::Rails::Subscribers::RenderedException.new
      request = debug_exception_request("/missing")
      request.set_header("action_dispatch.show_exceptions", :none)

      subscriber.call(request, ActionController::RoutingError.new('No route matches [POST] "/missing"'))

      assert_empty parse_records(output)
    end

    def test_rendered_exception_subscriber_respects_disabled_configuration
      output = configure_output
      configuration = Julewire::Rails::Configuration.new
      configuration.rendered_exceptions = false
      subscriber = Julewire::Rails::Subscribers::RenderedException.new(configuration)

      subscriber.call(
        debug_exception_request("/missing"),
        ActionController::RoutingError.new('No route matches [POST] "/missing"')
      )

      assert_empty parse_records(output)
    end

    def test_rendered_exception_subscriber_defaults_missing_rails_debug_exception_log_level
      output = configure_output
      subscriber = Julewire::Rails::Subscribers::RenderedException.new(rendered_exception_configuration)
      request = debug_exception_request("/missing")
      request.delete_header("action_dispatch.debug_exception_log_level")

      subscriber.call(request, ActionController::RoutingError.new('No route matches [POST] "/missing"'))

      record = parse_records(output).fetch(0)

      assert_equal "error", record.fetch("severity")
      assert_equal "action_dispatch.rendered_exception", record.fetch("event")
    end

    def test_rendered_exception_subscriber_records_adapter_failures
      subscriber = Julewire::Rails::Subscribers::RenderedException.new
      bad_request = Object.new
      bad_request.define_singleton_method(:get_header) { |_key| raise "bad request" }

      _health, integration = assert_julewire_integration_failure_contract(
        integration: :rails,
        component: :rendered_exception_subscriber,
        exercise: lambda do
          subscriber.call(
            bad_request,
            ActionController::RoutingError.new('No route matches [GET] "/bad"')
          )
        end
      )

      assert_equal :call, integration.dig(:last_failure, :action)
      assert_equal "RuntimeError", integration.dig(:last_failure, :class)
    end

    def test_rendered_exception_subscriber_install_is_idempotent
      next_configuration = Julewire::Rails::Configuration.new
      next_configuration.rendered_exceptions = false

      Julewire::Rails::Subscribers::RenderedException.reset!
      subscriber = Julewire::Rails::Subscribers::RenderedException.install!(Julewire::Rails::Configuration.new)
      reinstalled = Julewire::Rails::Subscribers::RenderedException.install!(next_configuration)

      assert_same subscriber, reinstalled
      assert_same next_configuration, reinstalled.instance_variable_get(:@configuration)
    ensure
      Julewire::Rails::Subscribers::RenderedException.reset!
    end

    def test_rendered_exception_subscriber_install_registers_public_interceptor
      registered = []
      debug_exceptions = ::ActionDispatch::DebugExceptions
      singleton_class = class << debug_exceptions; self; end
      original = debug_exceptions.method(:register_interceptor)
      verbose = $VERBOSE
      $VERBOSE = nil
      singleton_class.define_method(:register_interceptor) do |interceptor = nil, &block|
        registered << (interceptor || block)
      end
      Julewire::Rails::Subscribers::RenderedException.reset!

      subscriber = Julewire::Rails::Subscribers::RenderedException.install!(Julewire::Rails::Configuration.new)

      assert_same subscriber, registered.fetch(0)
    ensure
      Julewire::Rails::Subscribers::RenderedException.reset!
      $VERBOSE = nil
      singleton_class&.define_method(:register_interceptor, original)
      $VERBOSE = verbose
    end

    private

    def debug_exception_request(path)
      env = ::Rack::MockRequest.env_for(path, method: "POST")
      env["action_dispatch.backtrace_cleaner"] = ActiveSupport::BacktraceCleaner.new
      env["action_dispatch.debug_exception_log_level"] = ::Logger::ERROR
      ActionDispatch::Request.new(env)
    end

    def rendered_exception_configuration
      Julewire::Rails::Configuration.new.tap { it.rendered_exceptions = true }
    end
  end
end
