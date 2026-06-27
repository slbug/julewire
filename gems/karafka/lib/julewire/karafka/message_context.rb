# frozen_string_literal: true

module Julewire
  module Karafka
    module MessageContext
      class << self
        def call(message, configuration:, fields: nil, &)
          fields ||= PayloadReader.message_payload(message)
          call_fields(fields, configuration: configuration, &)
        end

        def call_fields(fields, configuration:, &)
          carrier = carrier_for(fields, configuration)

          result = Core::Propagation::Carrier.extract_result(
            carrier,
            key: configuration.carrier_key,
            max_bytes: configuration.carrier_max_bytes
          )
          record_carrier_restore_failure(result)
          fields = Core::Fields::FieldSet.deep_symbolize_keys(fields)

          Core::Propagation.restore(result.envelope, owned: true) do
            Core::Integration::Facade.with_neutral(message_neutral(fields)) do
              Core::Integration::Facade.with_attributes(message_attributes(fields), &)
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
          return unless configuration.propagation?

          headers = fields[:headers]
          headers = {} unless headers.is_a?(Hash)
          filter = configuration.carrier_filter
          return headers unless filter

          begin
            filtered = filter.call(headers, message: fields)
            filtered.is_a?(Hash) ? filtered : {}
          rescue StandardError => e
            IntegrationHealth.record_failure(e, action: :carrier_filter, component: :message_context)
            {}
          end
        end

        def message_attributes(fields) = { karafka: fields }

        def message_neutral(fields) = MessagingAttributes.message(fields)
      end
    end
  end
end
