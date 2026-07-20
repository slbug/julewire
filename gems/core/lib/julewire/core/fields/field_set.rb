# frozen_string_literal: true

module Julewire
  module Core
    module Fields
      # @api integration_spi
      module FieldSet
        Serializer = Serialization::Serializer
        TRUNCATION_METADATA_KEY = Serializer::TRUNCATION_METADATA_KEY.to_sym
        RESERVED_TRUNCATION_METADATA_ERROR =
          "#{Serializer::TRUNCATION_METADATA_KEY} is reserved for Julewire truncation metadata".freeze
        INVALID_MODES = %i[ignore raise wrap].freeze
        VALUE_KEY = :value
        private_constant :Serializer, :TRUNCATION_METADATA_KEY, :RESERVED_TRUNCATION_METADATA_ERROR, :INVALID_MODES

        class << self
          # Public ingress accepts String or Symbol keys. Core stores Symbol keys
          # after normalization so extension contracts stay simple.
          def coerce(fields = nil, keyword_fields = nil, invalid: :ignore)
            validate_invalid_mode!(invalid)
            coerced = {}
            coerce_fields!(coerced, fields, invalid: invalid) unless fields.nil?
            merge!(coerced, keyword_fields)
          end

          def merge(left, right)
            merge!(deep_symbolize_keys(left), right)
          end

          def merge!(target, fields)
            return target unless fields.is_a?(Hash)

            fields.each do |key, value|
              target[normalized_field_key(key)] = copy_field_value(value)
            end

            target
          end

          def deep_dup(value)
            deep_dup_with(value, preserve_truncation_metadata: false)
          end

          def deep_dup_owned(value)
            deep_dup_with(value, preserve_truncation_metadata: true)
          end

          def deep_symbolize_keys(value)
            deep_symbolize_keys_with(value, preserve_truncation_metadata: false)
          end

          def deep_symbolize_owned_keys(value)
            deep_symbolize_keys_with(value, preserve_truncation_metadata: true)
          end

          def frozen_copy(value)
            Internal.frozen_copy(value)
          end

          def value_for(hash, key, default: nil)
            return default unless hash.is_a?(Hash)

            hash.fetch(Internal.normalize_key(key), default)
          end

          private

          def deep_dup_with(value, preserve_truncation_metadata:)
            Serialization::ValueCopy.call(
              value,
              preserve_truncation_metadata: preserve_truncation_metadata
            )
          end

          def deep_symbolize_keys_with(value, preserve_truncation_metadata:)
            Serialization::ValueCopy.call(
              value,
              max_array_items: Serializer::DEFAULT_MAX_ARRAY_ITEMS,
              max_hash_keys: Serializer::DEFAULT_MAX_HASH_KEYS,
              max_string_bytes: Serializer::DEFAULT_MAX_STRING_BYTES,
              preserve_truncation_metadata: preserve_truncation_metadata,
              symbolize_keys: true
            )
          end

          def coerce_fields!(target, fields, invalid:)
            if fields.is_a?(Hash)
              merge!(target, fields)
            elsif invalid == :wrap
              target[VALUE_KEY] = copy_field_value(fields)
            elsif invalid == :raise
              raise ArgumentError, "fields must be a Hash"
            end
          end

          def validate_invalid_mode!(invalid)
            return if INVALID_MODES.include?(invalid)

            raise ArgumentError, "invalid field coercion mode: #{invalid.inspect}"
          end

          def normalized_field_key(key)
            normalized_key = Internal.normalize_key(key)
            raise ArgumentError, RESERVED_TRUNCATION_METADATA_ERROR if normalized_key == TRUNCATION_METADATA_KEY

            normalized_key
          end

          def copy_field_value(value) = deep_symbolize_keys(value)
        end
      end
    end
  end
end
