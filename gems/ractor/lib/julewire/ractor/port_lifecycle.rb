# frozen_string_literal: true

module Julewire
  module Ractor
    module PortLifecycle
      class << self
        def close(port)
          return unless port.respond_to?(:close)
          return if port.respond_to?(:closed?) && port.closed?

          port.close
        rescue StandardError
          nil
        end
      end
    end
  end
end
