# frozen_string_literal: true

module Julewire
  module Core
    module Fields
      # @api integration_spi
      module FieldSet
        VALUE_KEY = :value

        class << self
          # Public ingress accepts String or Symbol keys. Core stores Symbol keys
          # after normalization so extension contracts stay simple.
          def coerce(fields = nil, keyword_fields = {}, invalid: :ignore)
            coerced = {}
            coerce_fields!(coerced, fields, invalid: invalid) unless fields.nil?
            merge!(coerced, keyword_fields) unless keyword_fields.empty?
            coerced
          end

          def merge(left, right)
            merge!(deep_symbolize_keys(left), right)
          end

          def merge!(target, fields)
            return target unless fields.is_a?(Hash)

            fields.each do |key, value|
              target[Fields::Internal.normalize_key(key)] = copy_field_value(value)
            end

            target
          end

          def deep_dup(value)
            return {} if value.is_a?(Hash) && value.empty?
            return [] if value.is_a?(Array) && value.empty?

            Serialization::ValueCopy.call(value)
          end

          def deep_symbolize_keys(value)
            return {} if value.is_a?(Hash) && value.empty?
            return [] if value.is_a?(Array) && value.empty?

            Serialization::ValueCopy.call(value, symbolize_keys: true)
          end

          def frozen_copy(value)
            Fields::Internal.frozen_copy(value)
          end

          def value_for(hash, key, default: nil)
            return default unless hash.is_a?(Hash)

            normalized = key.is_a?(String) ? Fields::Internal.normalize_key(key) : key
            return hash[normalized] if hash.key?(normalized)

            default
          end

          private

          def coerce_fields!(target, fields, invalid:)
            if fields.is_a?(Hash)
              merge!(target, fields)
            elsif invalid == :wrap
              target[VALUE_KEY] = deep_dup(fields)
            elsif invalid == :raise
              raise ArgumentError, "fields must be a Hash"
            end
          end

          def copy_field_value(value) = deep_symbolize_keys(value)
        end
      end
    end
  end
end
