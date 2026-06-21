# frozen_string_literal: true

require "json"

module Julewire
  module Core
    module Propagation
      # @api public
      module Carrier
        DEFAULT_KEY = "julewire"
        DEFAULT_ENVELOPE = Core.sentinel(:default_envelope)
        private_constant :DEFAULT_ENVELOPE

        class << self
          def encode(envelope: DEFAULT_ENVELOPE, max_bytes: nil)
            Validation.validate_byte_limit!(max_bytes, name: :max_bytes)

            encoded = JSON.generate(serialized_envelope(envelope), allow_nan: false)
            return if max_bytes && encoded.bytesize > max_bytes

            encoded
          end

          def inject(carrier = {}, envelope: DEFAULT_ENVELOPE, key: DEFAULT_KEY, max_bytes: nil)
            validate_carrier!(carrier)
            encoded = encode(envelope: envelope, max_bytes: max_bytes)
            clear_carrier_key!(carrier, key) unless encoded
            return unless encoded

            carrier[key.to_s] = encoded
            carrier
          end

          def extract(carrier, key: DEFAULT_KEY)
            value = carrier_value(carrier, key)
            return {} unless value

            parsed = JSON.parse(value.to_s)
            parsed.is_a?(Hash) ? Fields::FieldSet.deep_symbolize_keys(parsed) : {}
          rescue StandardError
            {}
          end

          def restore(carrier, key: DEFAULT_KEY, link_executions: false, &)
            Propagation.restore(extract(carrier, key: key), link_executions: link_executions, &)
          end

          def serialized_envelope(envelope)
            return Propagation.capture if envelope.equal?(DEFAULT_ENVELOPE)

            Serialization::Serializer.call(envelope)
          end

          private

          def carrier_value(carrier, key)
            return unless carrier.respond_to?(:[])

            carrier[key.to_s] || carrier[Fields::Internal.normalize_key(key)]
          end

          def validate_carrier!(carrier)
            return if carrier.respond_to?(:[]=)

            raise ArgumentError, "carrier must support []="
          end

          def clear_carrier_key!(carrier, key)
            string_key = key.to_s
            symbol_key = Fields::Internal.normalize_key(key)
            if carrier.respond_to?(:delete)
              begin
                carrier.delete(string_key)
                carrier.delete(symbol_key)
              rescue StandardError
                clear_carrier_key_by_assignment(carrier, string_key, symbol_key)
              end
            else
              clear_carrier_key_by_assignment(carrier, string_key, symbol_key)
            end
          end

          def clear_carrier_key_by_assignment(carrier, string_key, symbol_key)
            carrier[string_key] = nil
            carrier[symbol_key] = nil
          rescue StandardError
            nil
          end
        end
      end
    end
  end
end
