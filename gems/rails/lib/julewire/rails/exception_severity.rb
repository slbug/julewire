# frozen_string_literal: true

module Julewire
  module Rails
    module ExceptionSeverity
      HEADER = "action_dispatch.debug_exception_log_level"
      SEVERITY = ::Julewire::Core::Records::Severity
      private_constant :HEADER, :SEVERITY

      class << self
        def for_request(request)
          SEVERITY.normalize(header_value(request))
        rescue ArgumentError
          :error
        end

        private

        def header_value(request)
          request.get_header(HEADER)
        rescue StandardError
          nil
        end
      end
    end
  end
end
