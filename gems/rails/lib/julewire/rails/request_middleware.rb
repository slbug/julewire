# frozen_string_literal: true

require "action_dispatch/http/request"
require "action_dispatch/middleware/exception_wrapper"
require "action_view"
require "active_support/log_subscriber"

module Julewire
  module Rails
    class RequestMiddleware
      REQUEST_ERROR_ENV_KEY = "julewire.rails.request_error"
      RENDERED_EXCEPTION_ENV_KEY = "julewire.rails.rendered_exception"

      def initialize(app, configuration = Configuration.new, taggers = nil)
        @app = app
        @configuration = configuration
        @taggers = taggers || []
      end

      def call(env)
        lifecycle = nil
        request = ::ActionDispatch::Request.new(env)
        RequestErrorOwnership.clear
        return Suppression.suppress { @app.call(env) } if excluded_request?(request)

        lifecycle = RequestLifecycle.new(
          configuration: @configuration,
          env: env,
          request: request,
          taggers: @taggers
        ).start
        request_context = RequestContext.new(configuration: @configuration, request: request)

        response = request_context.call do
          execution_handle = lifecycle.start_execution!(neutral: request_context.neutral_fields)
          execution_handle.run do
            call_app(request, env, execution_handle)
          end
        end

        lifecycle.attach_body_finalizer(response)
      rescue Exception => e # rubocop:disable Lint/RescueException -- Rack middleware must re-raise all application exits.
        lifecycle&.finish_error(e)
        raise
      ensure
        lifecycle&.finish_unattached
      end

      private

      def excluded_request?(request)
        @configuration.request_exclude_prefixes.any? { excluded_path?(request.path, it) }
      end

      def excluded_path?(path, prefix)
        return true if prefix == "/"

        path == prefix || path.start_with?("#{prefix}/")
      end

      def call_app(request, env, execution_handle)
        status, headers, body = @app.call(env)
        add_summary_fields(response_summary_attributes(request, status, headers))
        capture_rendered_request_error(request, env, status)
        [status, headers, body]
      rescue Exception => e # rubocop:disable Lint/RescueException -- Rack middleware must re-raise all application exits.
        severity = request_exception_severity(request)
        wrapper = exception_wrapper(request, e)
        own_request_error(env, e, severity: severity)
        add_summary_fields(error_summary_attributes(request, e, status: 500, wrapper: wrapper))
        execution_handle.finish(reason: :error, error: e, severity: severity)
        raise
      end

      def response_summary_attributes(request, status, headers)
        RequestAttributes.response_summary(request, status, headers)
      end

      def capture_rendered_request_error(request, env, status)
        rendered_error = env[RENDERED_EXCEPTION_ENV_KEY]
        if rendered_error
          own_request_error(env, rendered_error.fetch(:error), severity: rendered_error.fetch(:severity))
          add_summary_fields(rendered_error_summary_attributes(request, rendered_error, status: status))
          return
        end

        error = env["action_dispatch.exception"]
        return unless error

        severity = request_exception_severity(request)
        wrapper = exception_wrapper(request, error)
        own_request_error(env, error, severity: severity)
        add_summary_fields(error_summary_attributes(request, error, status: status, wrapper: wrapper))
      end

      def own_request_error(env, error, severity:)
        return unless @configuration.request_summary?

        env[REQUEST_ERROR_ENV_KEY] = { error: error, severity: severity }
        RequestErrorOwnership.mark(error)
      end

      def rendered_error_summary_attributes(request, rendered_error, status:)
        RequestAttributes.rendered_error_summary(
          request,
          rendered_error,
          status: status
        )
      end

      def error_summary_attributes(request, error, status:, wrapper:)
        RequestAttributes.error_summary(request, error, status: status, wrapper: wrapper)
      end

      def request_exception_severity(request)
        ExceptionSeverity.for_request(request)
      end

      def exception_wrapper(request, error)
        cleaner = request.get_header("action_dispatch.backtrace_cleaner")
        ::ActionDispatch::ExceptionWrapper.new(cleaner, error)
      end

      def add_summary_fields(fields)
        Core::Integration::Facade.add_summary_attributes(fields[:attributes])
        Core::Integration::Facade.add_summary_neutral(fields[:neutral])
      end
    end
  end
end
