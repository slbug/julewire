# frozen_string_literal: true

require "action_dispatch/middleware/debug_exceptions"

module Julewire
  module Rails
    module DebugExceptionLogSilencer
      module Patch
        def log_error(request, wrapper)
          return if DebugExceptionLogSilencer.suppress?

          super
        end
      end
      private_constant :Patch

      class << self
        def install!(configuration)
          @configuration = configuration

          ::ActionDispatch::DebugExceptions.prepend(Patch)
        end

        def suppress?
          configuration = @configuration
          return false unless configuration

          case configuration.reported_exception_logs
          when :auto
            configuration.logger? && (configuration.request_summary? || configuration.error_reports?)
          else
            !configuration.reported_exception_logs
          end
        rescue StandardError => e
          IntegrationHealth.record_failure(
            e,
            action: :suppress?,
            component: :debug_exception_log_silencer
          )
        end
      end
    end
  end
end
