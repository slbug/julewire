# frozen_string_literal: true

module Julewire
  module Core
    module Records
      # Converts raw emit input into known record fields plus payload fields.
      # @api bridge_spi
      module BuildInput
        RECORD_INPUT_KEYS = Record::REQUIRED_KEYS.freeze
        RECORD_INPUT_KEY_SET = RECORD_INPUT_KEYS.to_h { [it, true] }.freeze
        private_constant :RECORD_INPUT_KEYS, :RECORD_INPUT_KEY_SET

        class << self
          def normalize_public(input)
            return {} if input.nil?
            return normalize_public_hash(input) if RawInput.hash_input?(input)

            { message: input.to_s }
          end

          def validate_owned(input)
            raise TypeError, "owned record input must be a Hash" unless input.is_a?(Hash)

            Serialization::DeepFreeze.validate_symbol_keys(input)
            validate_known_keys!(input)
            input
          end

          private

          def validate_known_keys!(input)
            unknown = input.each_key.reject { RECORD_INPUT_KEY_SET.key?(it) }
            return if unknown.empty?

            raise TypeError, "owned record input has unknown top-level keys: #{unknown.join(", ")}"
          end

          def normalize_public_hash(input)
            normalized = {}
            payload_fields = {}
            input.each do |key, raw_value|
              normalized_key = Fields::Internal.normalize_key(key)
              value = raw_value.equal?(input) ? CIRCULAR_REFERENCE : raw_value
              if RECORD_INPUT_KEY_SET.key?(normalized_key)
                normalized[normalized_key] = value
              else
                payload_fields[normalized_key] = value
              end
            end
            merge_unknown_payload!(normalized, payload_fields)
            normalized
          end

          def merge_unknown_payload!(normalized, payload_fields)
            return if payload_fields.empty?

            normalized[:payload] = if normalized.key?(:payload)
                                     merge_payload_input(normalized.fetch(:payload), payload_fields)
                                   else
                                     payload_fields
                                   end
          end

          def merge_payload_input(explicit_payload, unknown_payload)
            if explicit_payload.is_a?(Hash)
              Fields::FieldSet.merge(unknown_payload, explicit_payload)
            else
              Fields::FieldSet.merge(unknown_payload, Fields::FieldSet::VALUE_KEY => explicit_payload)
            end
          end
        end
      end
    end
  end
end
