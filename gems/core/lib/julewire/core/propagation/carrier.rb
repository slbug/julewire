# frozen_string_literal: true

require "json"

module Julewire
  module Core
    module Propagation
      # @api public
      module Carrier
        DEFAULT_KEY = "julewire"
        DEFAULT_MAX_BYTES = 65_536
        DEFAULT_ENVELOPE = Core.sentinel(:default_envelope)
        class Extracted
          attr_reader :envelope, :status, :reason, :error

          def initialize(envelope:, status:, reason: nil, error: nil)
            @envelope = envelope
            @status = status
            @reason = reason
            @error = error
          end

          def failure? = !error.nil?
        end
        private_constant :DEFAULT_ENVELOPE
        private_constant :Extracted

        # @api integration_spi
        class ExtractionError < StandardError
          attr_reader :status, :reason

          def initialize(status, reason)
            @status = status
            @reason = reason
            super(reason)
          end
        end

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

          def extract(carrier, key: DEFAULT_KEY, max_bytes: DEFAULT_MAX_BYTES)
            extract_result(carrier, key: key, max_bytes: max_bytes).envelope
          end

          # @api integration_spi
          def extract_result(carrier, key: DEFAULT_KEY, max_bytes: DEFAULT_MAX_BYTES)
            Validation.validate_byte_limit!(max_bytes, name: :max_bytes)

            extract_payload(carrier, key: key, max_bytes: max_bytes)
          end

          def restore(carrier, key: DEFAULT_KEY, link_executions: false, max_bytes: DEFAULT_MAX_BYTES, &)
            envelope = extract_result(carrier, key: key, max_bytes: max_bytes).envelope
            Propagation.restore(envelope, link_executions: link_executions, owned: true, &)
          end

          def serialized_envelope(envelope)
            return Propagation.capture if envelope.equal?(DEFAULT_ENVELOPE)

            Serialization::Serializer.call(envelope)
          end

          private

          def extract_payload(carrier, key:, max_bytes:)
            value = carrier_value(carrier, key)
            return extracted({}, :missing) unless value

            string = value.to_s
            if max_bytes && string.bytesize > max_bytes
              return extracted_failure(:oversized, "carrier payload exceeds max_bytes")
            end

            parsed = JSON.parse(string)
            return extracted_failure(:non_hash, "carrier payload must be a JSON object") unless parsed.is_a?(Hash)

            extracted(Fields::FieldSet.deep_symbolize_owned_keys(parsed), :ok)
          rescue StandardError => e
            extracted_failure(:malformed, "carrier payload is not valid JSON", e)
          end

          def extracted(envelope, status)
            Extracted.new(envelope: envelope, status: status)
          end

          def extracted_failure(status, reason, cause = nil)
            error = ExtractionError.new(status, reason)
            error.set_backtrace(cause.backtrace) if cause&.backtrace
            Extracted.new(envelope: {}, status: status, reason: reason, error: error)
          end

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
