# frozen_string_literal: true

require "action_dispatch/middleware/debug_exceptions"

module Julewire
  module Rails
    module Subscribers
      class RenderedException
        class << self
          include Core::Integration::SubscriberInstall

          def install!(configuration)
            return reset! unless configuration.request_summary? || configuration.rendered_exceptions?
            return unless defined?(::ActionDispatch::DebugExceptions)
            return unless ::ActionDispatch::DebugExceptions.respond_to?(:register_interceptor)

            install_subscriber(configuration, enabled: true) do |subscriber|
              ::ActionDispatch::DebugExceptions.register_interceptor(subscriber)
              -> { unregister_interceptor(subscriber) }
            end
          end

          private

          def unregister_interceptor(subscriber)
            return unless ::ActionDispatch::DebugExceptions.respond_to?(:interceptors)

            ::ActionDispatch::DebugExceptions.interceptors.delete(subscriber)
          end
        end

        def initialize(configuration = Configuration.new)
          @configuration = configuration
        end

        attr_writer :configuration

        def call(request, exception)
          return if Suppression.active?

          wrapper = exception_wrapper(request, exception)
          return unless showable_response?(request, wrapper)

          capture_request_error(request, exception, wrapper)
          unless @configuration.rendered_exceptions?
            IntegrationHealth.record_success(action: :call, component: :rendered_exception_subscriber)
            return
          end

          Core::Integration::Facade.emit(
            severity: severity_for(request, wrapper),
            event: "action_dispatch.rendered_exception",
            logger: "ActionDispatch::DebugExceptions",
            source: @configuration.source,
            attributes: attributes_for(request, wrapper),
            neutral: neutral_for(request, wrapper),
            error: exception
          )
          IntegrationHealth.record_success(action: :call, component: :rendered_exception_subscriber)
        rescue StandardError => e
          IntegrationHealth.record_failure(
            e,
            action: :call,
            component: :rendered_exception_subscriber
          )
        end

        private

        def exception_wrapper(request, exception)
          cleaner = request.get_header("action_dispatch.backtrace_cleaner")
          ::ActionDispatch::ExceptionWrapper.new(cleaner, exception)
        end

        def showable_response?(request, wrapper)
          wrapper.show?(request)
        rescue StandardError
          false
        end

        def capture_request_error(request, exception, wrapper)
          return unless @configuration.request_summary?

          request.set_header(
            RequestMiddleware::RENDERED_EXCEPTION_ENV_KEY,
            {
              error: exception,
              severity: severity_for(request, wrapper),
              status: status_code(wrapper),
              rescue_response: rescue_response?(wrapper),
              rescue_template: rescue_template(wrapper)
            }
          )
          RequestErrorOwnership.mark(exception)
        end

        def severity_for(request, _wrapper)
          ExceptionSeverity.for_request(request)
        end

        def attributes_for(request, wrapper)
          {
            rails: {
              rescue_response: rescue_response?(wrapper),
              request_method: request.request_method,
              path: request.path,
              status: status_code(wrapper),
              rescue_template: rescue_template(wrapper)
            }.compact
          }
        end

        def neutral_for(request, wrapper)
          Core::Fields::AttributeKeys.fields(
            Core::Fields::AttributeKeys::HTTP_REQUEST_METHOD => request.request_method,
            Core::Fields::AttributeKeys::URL_PATH => request.path,
            Core::Fields::AttributeKeys::HTTP_RESPONSE_STATUS_CODE => status_code(wrapper)
          )
        end

        def status_code(wrapper)
          wrapper.status_code
        rescue StandardError
          nil
        end

        def rescue_response?(wrapper)
          wrapper.rescue_response?
        rescue StandardError
          false
        end

        def rescue_template(wrapper)
          wrapper.rescue_template
        rescue StandardError
          nil
        end
      end
    end
  end
end
