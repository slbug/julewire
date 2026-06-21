# frozen_string_literal: true

module Julewire
  module Karafka
    module MessageContext
      class << self
        def call(message, configuration:, fields: nil, &)
          raise ArgumentError, "block required" unless block_given?

          fields ||= PayloadReader.message_payload(message)
          carrier = carrier_for(fields, configuration)

          Julewire::Core::Propagation::Carrier.restore(carrier, key: configuration.carrier_key) do
            Julewire::Core::Integration::Facade.with_neutral(message_neutral(fields)) do
              Julewire::Core::Integration::Facade.with_attributes(message_attributes(fields), &)
            end
          end
        end

        private

        def carrier_for(fields, configuration)
          return {} unless configuration.propagation?

          headers = fields[:headers].is_a?(Hash) ? fields[:headers] : {}
          filter = configuration.carrier_filter
          return headers unless filter

          filtered = filter.call(headers, message: fields)
          filtered.is_a?(Hash) ? filtered : {}
        rescue StandardError => e
          IntegrationHealth.record_failure(e, action: :carrier_filter, component: :message_context)
          {}
        end

        def message_attributes(fields) = { karafka: fields }

        def message_neutral(fields) = MessagingAttributes.message(fields)
      end
    end
  end
end
