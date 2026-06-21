# frozen_string_literal: true

module Julewire
  module Karafka
    class WaterdropMiddleware
      def initialize(configuration: Configuration.new)
        @configuration = configuration
      end

      attr_writer :configuration

      def call(message)
        inject_carrier(message) if @configuration.propagation?
        message
      end

      private

      def inject_carrier(message)
        IntegrationHealth.with_failure_health(action: :carrier_inject, component: :waterdrop_middleware) do
          headers = headers_for(message)
          Julewire::Core::Propagation::Carrier.inject(
            headers,
            key: @configuration.carrier_key,
            max_bytes: @configuration.carrier_max_bytes
          )
        end
      end

      def headers_for(message)
        if message.respond_to?(:headers)
          message.headers ||= {}
        elsif message.is_a?(Hash)
          message[:headers] ||= {}
        else
          {}
        end
      end
    end
  end
end
