# frozen_string_literal: true

module Julewire
  module Ractor
    module PortLifecycle
      class << self
        def with_port(port = ::Ractor::Port.new)
          yield port
        ensure
          close(port)
        end

        def close(port)
          return unless port.respond_to?(:close)

          port.close
          nil
        rescue StandardError
          nil
        end
      end
    end
  end
end
