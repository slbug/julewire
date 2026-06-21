# frozen_string_literal: true

module Julewire
  module Karafka
    module MessageContext
      class << self
        def call(message, configuration:, fields: nil, &)
          raise ArgumentError, "block required" unless block_given?

          fields ||= PayloadReader.message_payload(message)
          carrier = carrier_for(fields, configuration)

          result = Julewire::Core::Propagation::Carrier.extract_result(
            carrier,
            key: configuration.carrier_key,
            max_bytes: configuration.carrier_max_bytes
          )
          record_carrier_restore_failure(result)

          Julewire::Core::Propagation.restore(result.envelope) do
            Julewire::Core::Integration::Facade.with_neutral(message_neutral(fields)) do
              Julewire::Core::Integration::Facade.with_attributes(message_attributes(fields), &)
            end
          end
        end

        private

        def record_carrier_restore_failure(result)
          return unless result.failure?

          IntegrationHealth.record_failure(
            result.error,
            action: :carrier_restore,
            component: :message_context,
            status: result.status,
            reason: result.reason
          )
        end

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
