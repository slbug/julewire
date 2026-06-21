# frozen_string_literal: true

require "action_dispatch/middleware/debug_exceptions"

module Julewire
  module Rails
    module DebugExceptionLogSilencer
      Patch = Module.new do
        def log_error(request, wrapper)
          return if Julewire::Rails::DebugExceptionLogSilencer.suppress?(request, wrapper)

          super
        end
      end
      private_constant :Patch

      class << self
        def install!(configuration)
          @configuration = configuration
          return false unless defined?(::ActionDispatch::DebugExceptions)
          return true if @installed

          ::ActionDispatch::DebugExceptions.prepend(Patch)
          @installed = true
        end

        def suppress?(_request, _wrapper)
          suppress_reported_logs?
        rescue StandardError => e
          IntegrationHealth.record_failure(
            e,
            action: :suppress?,
            component: :debug_exception_log_silencer
          )
        end

        private

        def suppress_reported_logs?
          configuration = @configuration
          return false unless configuration

          case configuration.reported_exception_logs
          when :auto
            configuration.logger? && (configuration.request_summary? || configuration.error_reports?)
          else
            !configuration.reported_exception_logs
          end
        end
      end
    end
  end
end
