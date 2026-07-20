# frozen_string_literal: true

require "test_helper"
require "action_dispatch/testing/test_request"

module Julewire
  class TestRenderedExceptionSubscriber < Minitest::Test
    cover Julewire::Rails::Subscribers::RenderedException
    cover Julewire::Rails::RequestMiddleware
    cover Julewire::Rails::RequestErrorOwnership
    def test_rendered_exception_subscriber_emits_rescued_response_records
      captured = []
      output = configure_output(captured: captured)
      subscriber = Julewire::Rails::Subscribers::RenderedException.new(rendered_exception_configuration)
      request = debug_exception_request("/missing")
      request.set_header("action_dispatch.debug_exception_log_level", ::Logger::WARN)

      subscriber.call(
        request,
        ActionController::RoutingError.new('No route matches [POST] "/missing"')
      )

      record = parse_records(output).fetch(0)
      raw_record = captured.fetch(0).to_h

      assert_equal "warn", record.fetch("severity")
      assert_equal "action_dispatch.rendered_exception", record.fetch("event")
      assert_equal "ActionDispatch::DebugExceptions", record.fetch("logger")
      assert_equal "rails", record.fetch("source")
      assert_equal 404, record.dig("attributes", "rails", "status")
      assert_true record.dig("attributes", "rails", "rescue_response")
      assert_equal "routing_error", record.dig("attributes", "rails", "rescue_template")
      assert_equal "POST", record.dig("attributes", "rails", "request_method")
      assert_equal "/missing", record.dig("attributes", "rails", "path")
      assert_equal "POST", raw_record.dig(:neutral, :"http.request.method")
      assert_equal "/missing", raw_record.dig(:neutral, :"url.path")
      assert_equal 404, raw_record.dig(:neutral, :"http.response.status_code")
      assert_equal "ActionController::RoutingError", record.dig("error", "class")
      assert_equal :ok, Julewire.health.dig(:process_integrations, :rails, :status)
    end

    def test_rendered_exception_subscriber_leaves_unhandled_app_errors_to_rails_error
      output = configure_output
      subscriber = Julewire::Rails::Subscribers::RenderedException.new(rendered_exception_configuration)

      subscriber.call(debug_exception_request("/boom"), RuntimeError.new("boom"))

      record = parse_records(output).fetch(0)

      assert_equal "action_dispatch.rendered_exception", record.fetch("event")
      assert_equal 500, record.dig("attributes", "rails", "status")
      assert_false record.dig("attributes", "rails", "rescue_response")
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
      subscriber = Julewire::Rails::Subscribers::RenderedException.new(rendered_exception_configuration)
      request = debug_exception_request("/missing")
      request.set_header("action_dispatch.show_exceptions", :none)
      exception = ActionController::RoutingError.new('No route matches [POST] "/missing"')

      subscriber.call(request, exception)

      assert_empty parse_records(output)
      assert_nil request.get_header(Julewire::Rails::RequestMiddleware::RENDERED_EXCEPTION_ENV_KEY)
      assert_false Julewire::Rails::RequestErrorOwnership.consume?(exception)
    end

    def test_rendered_exception_subscriber_suppression_skips_emit_capture_and_health
      output = configure_output
      subscriber = Julewire::Rails::Subscribers::RenderedException.new(rendered_exception_configuration)
      request = debug_exception_request("/missing")
      exception = ActionController::RoutingError.new('No route matches [POST] "/missing"')

      Julewire::Rails::Suppression.suppress do
        subscriber.call(request, exception)
      end

      assert_empty parse_records(output)
      assert_nil request.get_header(Julewire::Rails::RequestMiddleware::RENDERED_EXCEPTION_ENV_KEY)
      assert_false Julewire::Rails::RequestErrorOwnership.consume?(exception)
      assert_false Julewire.health.fetch(:process_integrations).key?(:rails)
    end

    def test_rendered_exception_subscriber_disabled_emit_still_captures_request_summary
      output = configure_output
      configuration = Julewire::Rails::Configuration.new
      configuration.rendered_exceptions = false
      subscriber = Julewire::Rails::Subscribers::RenderedException.new(configuration)
      request = debug_exception_request("/missing")
      exception = ActionController::RoutingError.new('No route matches [POST] "/missing"')

      subscriber.call(request, exception)

      assert_empty parse_records(output)
      rendered_error = request.get_header(Julewire::Rails::RequestMiddleware::RENDERED_EXCEPTION_ENV_KEY)

      assert_same exception, rendered_error.fetch(:error)
      assert_equal :error, rendered_error.fetch(:severity)
      assert_equal 404, rendered_error.fetch(:status)
      assert_true rendered_error.fetch(:rescue_response)
      assert_equal "routing_error", rendered_error.fetch(:rescue_template)
      assert_true Julewire::Rails::RequestErrorOwnership.consume?(exception)
      assert_equal :ok, Julewire.health.dig(:process_integrations, :rails, :status)
    end

    def test_rendered_exception_subscriber_summary_capture_uses_request_severity_and_unhandled_shape
      output = configure_output
      configuration = Julewire::Rails::Configuration.new
      configuration.rendered_exceptions = false
      subscriber = Julewire::Rails::Subscribers::RenderedException.new(configuration)
      request = debug_exception_request("/boom")
      request.set_header("action_dispatch.debug_exception_log_level", ::Logger::WARN)
      exception = RuntimeError.new("boom")

      subscriber.call(request, exception)

      assert_empty parse_records(output)
      rendered_error = request.get_header(Julewire::Rails::RequestMiddleware::RENDERED_EXCEPTION_ENV_KEY)

      assert_same exception, rendered_error.fetch(:error)
      assert_equal :warn, rendered_error.fetch(:severity)
      assert_equal 500, rendered_error.fetch(:status)
      assert_false rendered_error.fetch(:rescue_response)
      assert_equal "diagnostics", rendered_error.fetch(:rescue_template)
      assert_true Julewire::Rails::RequestErrorOwnership.consume?(exception)
    end

    def test_rendered_exception_subscriber_skips_request_capture_when_summary_is_disabled
      output = configure_output
      configuration = rendered_exception_configuration
      configuration.request_summary = false
      subscriber = Julewire::Rails::Subscribers::RenderedException.new(configuration)
      request = debug_exception_request("/missing")
      exception = ActionController::RoutingError.new('No route matches [POST] "/missing"')

      subscriber.call(request, exception)

      record = parse_records(output).fetch(0)

      assert_equal "action_dispatch.rendered_exception", record.fetch("event")
      assert_nil request.get_header(Julewire::Rails::RequestMiddleware::RENDERED_EXCEPTION_ENV_KEY)
      assert_false Julewire::Rails::RequestErrorOwnership.consume?(exception)
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

    def test_rendered_exception_subscriber_uses_backtrace_cleaner_header_key
      output = configure_output
      subscriber = Julewire::Rails::Subscribers::RenderedException.new(rendered_exception_configuration)
      request = debug_exception_request("/missing")
      original_get_header = request.method(:get_header)
      request.define_singleton_method(:get_header) do |key|
        raise "unexpected blank header key" if key.to_s.empty?

        original_get_header.call(key)
      end

      subscriber.call(request, ActionController::RoutingError.new('No route matches [POST] "/missing"'))

      assert_equal "action_dispatch.rendered_exception", parse_records(output).fetch(0).fetch("event")
    end

    def test_rendered_exception_subscriber_uses_top_level_action_dispatch_wrapper
      output = configure_output
      subscriber = Julewire::Rails::Subscribers::RenderedException.new(rendered_exception_configuration)
      shadow = Module.new do
        const_set(
          :ExceptionWrapper,
          Class.new do
            def self.new(*)
              raise "shadow ActionDispatch wrapper used"
            end
          end
        )
      end

      with_constant(Julewire::Rails::Subscribers::RenderedException, :ActionDispatch, shadow) do
        subscriber.call(
          debug_exception_request("/missing"),
          ActionController::RoutingError.new('No route matches [POST] "/missing"')
        )
      end

      assert_equal "action_dispatch.rendered_exception", parse_records(output).fetch(0).fetch("event")
    end

    def test_rendered_exception_subscriber_passes_backtrace_cleaner_to_exception_wrapper
      output = configure_output
      subscriber = Julewire::Rails::Subscribers::RenderedException.new(rendered_exception_configuration)
      request = debug_exception_request("/missing")
      cleaner = request.get_header("action_dispatch.backtrace_cleaner")
      exception = ActionController::RoutingError.new('No route matches [POST] "/missing"')
      wrapper = Object.new
      wrapper.define_singleton_method(:show?) { |_request| true }
      wrapper.define_singleton_method(:status_code) { 404 }
      wrapper.define_singleton_method(:rescue_response?) { true }
      wrapper.define_singleton_method(:rescue_template) { "routing_error" }
      seen = []
      wrapper_class = Class.new do
        define_singleton_method(:new) do |passed_cleaner, passed_exception|
          seen << [passed_cleaner, passed_exception]
          wrapper
        end
      end

      with_constant(::ActionDispatch, :ExceptionWrapper, wrapper_class) do
        subscriber.call(request, exception)
      end

      assert_equal "action_dispatch.rendered_exception", parse_records(output).fetch(0).fetch("event")
      assert_equal [[cleaner, exception]], seen
    end

    def test_rendered_exception_subscriber_uses_top_level_core_namespace
      output = configure_output
      subscriber = Julewire::Rails::Subscribers::RenderedException.new(rendered_exception_configuration)
      shadow = Module.new do
        def self.const_missing(_name)
          raise "shadow Core namespace used"
        end
      end

      with_constant(Julewire::Rails, :Core, shadow) do
        subscriber.call(
          debug_exception_request("/missing"),
          ActionController::RoutingError.new('No route matches [POST] "/missing"')
        )
      end

      record = parse_records(output).fetch(0)

      assert_equal "action_dispatch.rendered_exception", record.fetch("event")
      assert_equal "POST", record.dig("attributes", "rails", "request_method")
    end

    def test_rendered_exception_subscriber_default_configuration_captures_request_summary
      output = configure_output
      subscriber = Julewire::Rails::Subscribers::RenderedException.new
      request = debug_exception_request("/missing")
      exception = ActionController::RoutingError.new('No route matches [POST] "/missing"')

      subscriber.call(request, exception)

      assert_empty parse_records(output)
      rendered_error = request.get_header(Julewire::Rails::RequestMiddleware::RENDERED_EXCEPTION_ENV_KEY)

      assert_same exception, rendered_error.fetch(:error)
      assert_equal 404, rendered_error.fetch(:status)
    end

    def test_rendered_exception_subscriber_skips_when_wrapper_show_raises
      output = configure_output
      subscriber = Julewire::Rails::Subscribers::RenderedException.new(rendered_exception_configuration)
      request = debug_exception_request("/missing")
      wrapper = Object.new
      wrapper.define_singleton_method(:show?) { |_request| raise "show failed" }
      subscriber.define_singleton_method(:exception_wrapper) { |_request, _exception| wrapper }

      subscriber.call(request, ActionController::RoutingError.new('No route matches [POST] "/missing"'))

      assert_empty parse_records(output)
      assert_nil request.get_header(Julewire::Rails::RequestMiddleware::RENDERED_EXCEPTION_ENV_KEY)
      assert_false Julewire.health.fetch(:process_integrations).key?(:rails)
    end

    def test_rendered_exception_subscriber_contains_wrapper_metadata_failures
      output = configure_output
      subscriber = Julewire::Rails::Subscribers::RenderedException.new(rendered_exception_configuration)
      request = debug_exception_request("/missing")
      exception = ActionController::RoutingError.new('No route matches [POST] "/missing"')
      wrapper = Object.new
      wrapper.define_singleton_method(:show?) { |_request| true }
      wrapper.define_singleton_method(:status_code) { raise "status failed" }
      wrapper.define_singleton_method(:rescue_response?) { raise "response failed" }
      wrapper.define_singleton_method(:rescue_template) { raise "template failed" }
      subscriber.define_singleton_method(:exception_wrapper) { |_request, _exception| wrapper }

      subscriber.call(request, exception)

      record = parse_records(output).fetch(0)
      rendered_error = request.get_header(Julewire::Rails::RequestMiddleware::RENDERED_EXCEPTION_ENV_KEY)

      assert_equal "action_dispatch.rendered_exception", record.fetch("event")
      assert_false record.dig("attributes", "rails", "rescue_response")
      assert_false record.dig("attributes", "rails").key?("status")
      assert_false record.dig("attributes", "rails").key?("rescue_template")
      assert_nil rendered_error.fetch(:status)
      assert_false rendered_error.fetch(:rescue_response)
      assert_nil rendered_error.fetch(:rescue_template)
    end

    def test_rendered_exception_subscriber_records_adapter_failures
      subscriber = Julewire::Rails::Subscribers::RenderedException.new
      bad_request = Object.new
      bad_request.define_singleton_method(:get_header) { |_key| raise "bad request" }

      assert_nil subscriber.call(
        bad_request,
        ActionController::RoutingError.new('No route matches [GET] "/bad"')
      )

      health = Julewire.health
      integration = health.dig(:process_integrations, :rails)

      assert_equal :degraded, health.fetch(:status)
      assert_equal :degraded, integration.fetch(:status)
      assert_equal 1, integration.dig(:counts, :failures)
      assert_equal :rendered_exception_subscriber, integration.dig(:last_failure, :component)
      assert_equal :call, integration.dig(:last_failure, :action)
      assert_equal "RuntimeError", integration.dig(:last_failure, :class)
      refute_includes integration.fetch(:last_failure), :message
    end

    def test_rendered_exception_subscriber_install_is_idempotent
      output = configure_output
      next_configuration = Julewire::Rails::Configuration.new
      next_configuration.rendered_exceptions = false
      request = debug_exception_request("/missing")
      exception = ActionController::RoutingError.new('No route matches [GET] "/missing"')

      Julewire::Rails::Subscribers::RenderedException.reset!
      subscriber = Julewire::Rails::Subscribers::RenderedException.install!(Julewire::Rails::Configuration.new)
      reinstalled = Julewire::Rails::Subscribers::RenderedException.install!(next_configuration)
      reinstalled.call(request, exception)

      assert_same subscriber, reinstalled
      assert_empty parse_records(output)
      assert_same exception,
                  request.get_header(Julewire::Rails::RequestMiddleware::RENDERED_EXCEPTION_ENV_KEY).fetch(:error)
    ensure
      Julewire::Rails::Subscribers::RenderedException.reset!
    end

    def test_rendered_exception_subscriber_install_registers_public_interceptor
      registered = []
      debug_exceptions = ::ActionDispatch::DebugExceptions
      replacement = proc do |interceptor = nil, &block|
        registered << (interceptor || block)
      end

      subscriber = with_overridden_singleton_method(debug_exceptions, :register_interceptor, replacement) do
        Julewire::Rails::Subscribers::RenderedException.reset!
        Julewire::Rails::Subscribers::RenderedException.install!(Julewire::Rails::Configuration.new)
      end

      assert_same subscriber, registered.fetch(0)
    ensure
      Julewire::Rails::Subscribers::RenderedException.reset!
    end

    def test_rendered_exception_subscriber_installs_for_rendered_exceptions_without_request_summary
      top_level_dispatch = Module.new
      top_level_exceptions = debug_exceptions_stub
      top_level_dispatch.const_set(:DebugExceptions, top_level_exceptions)
      configuration = rendered_exception_configuration
      configuration.request_summary = false

      with_constant(Object, :ActionDispatch, top_level_dispatch) do
        Julewire::Rails::Subscribers::RenderedException.reset!
        subscriber = Julewire::Rails::Subscribers::RenderedException.install!(configuration)

        assert_instance_of Julewire::Rails::Subscribers::RenderedException, subscriber
        assert_includes top_level_exceptions.interceptors, subscriber
      end
    ensure
      Julewire::Rails::Subscribers::RenderedException.reset!
    end

    def test_rendered_exception_subscriber_disabled_install_resets_without_registering
      top_level_dispatch = Module.new
      top_level_exceptions = debug_exceptions_stub
      top_level_dispatch.const_set(:DebugExceptions, top_level_exceptions)
      configuration = Julewire::Rails::Configuration.new
      configuration.request_summary = false
      configuration.rendered_exceptions = false

      with_constant(Object, :ActionDispatch, top_level_dispatch) do
        assert_nil Julewire::Rails::Subscribers::RenderedException.install!(configuration)
        assert_empty top_level_exceptions.interceptors
      end
    ensure
      Julewire::Rails::Subscribers::RenderedException.reset!
    end

    def test_rendered_exception_subscriber_disabled_install_resets_existing_interceptor
      top_level_dispatch = Module.new
      top_level_exceptions = debug_exceptions_stub
      top_level_dispatch.const_set(:DebugExceptions, top_level_exceptions)
      disabled = Julewire::Rails::Configuration.new
      disabled.request_summary = false
      disabled.rendered_exceptions = false

      with_constant(Object, :ActionDispatch, top_level_dispatch) do
        Julewire::Rails::Subscribers::RenderedException.reset!
        subscriber = Julewire::Rails::Subscribers::RenderedException.install!(Julewire::Rails::Configuration.new)

        assert_includes top_level_exceptions.interceptors, subscriber
        assert_nil Julewire::Rails::Subscribers::RenderedException.install!(disabled)
        assert_empty top_level_exceptions.interceptors
        refute_predicate Julewire::Rails::Subscribers::RenderedException, :installed?
      end
    ensure
      Julewire::Rails::Subscribers::RenderedException.reset!
    end

    def test_rendered_exception_subscriber_reset_unregisters_top_level_interceptor
      top_level_dispatch = Module.new
      top_level_exceptions = debug_exceptions_stub
      nested_dispatch = Module.new
      nested_exceptions = debug_exceptions_stub
      top_level_dispatch.const_set(:DebugExceptions, top_level_exceptions)
      nested_dispatch.const_set(:DebugExceptions, nested_exceptions)

      with_constant(Object, :ActionDispatch, top_level_dispatch) do
        with_constant(Julewire::Rails::Subscribers::RenderedException, :ActionDispatch, nested_dispatch) do
          Julewire::Rails::Subscribers::RenderedException.reset!
          subscriber = Julewire::Rails::Subscribers::RenderedException.install!(Julewire::Rails::Configuration.new)

          assert_includes top_level_exceptions.interceptors, subscriber
          assert_empty nested_exceptions.interceptors

          Julewire::Rails::Subscribers::RenderedException.reset!

          refute_includes top_level_exceptions.interceptors, subscriber
          assert_empty nested_exceptions.interceptors
        end
      end
    ensure
      Julewire::Rails::Subscribers::RenderedException.reset!
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

    def debug_exceptions_stub
      Class.new do
        @interceptors = []

        class << self
          attr_reader :interceptors

          def register_interceptor(interceptor = nil, &block)
            @interceptors << (interceptor || block)
          end
        end
      end
    end
  end
end
