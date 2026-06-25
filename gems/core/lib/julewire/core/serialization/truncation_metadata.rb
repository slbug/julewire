# frozen_string_literal: true

module Julewire
  module Core
    module Serialization
      module TruncationMetadata
        KEYS = {
          string: {
            truncated: "truncated",
            truncated_fields: "truncated_fields",
            limits: "limits",
            max_array_items: "max_array_items",
            max_depth: "max_depth",
            max_hash_keys: "max_hash_keys",
            max_string_bytes: "max_string_bytes"
          }.freeze,
          symbol: {
            truncated: :truncated,
            truncated_fields: :truncated_fields,
            limits: :limits,
            max_array_items: :max_array_items,
            max_depth: :max_depth,
            max_hash_keys: :max_hash_keys,
            max_string_bytes: :max_string_bytes
          }.freeze
        }.freeze
        METADATA_KEYS = KEYS.fetch(:symbol).values_at(:truncated, :truncated_fields, :limits).freeze
        METADATA_KEY_NAMES = METADATA_KEYS.map(&:to_s).freeze
        LIMIT_KEYS = KEYS.fetch(:symbol).values_at(
          :max_array_items,
          :max_depth,
          :max_hash_keys,
          :max_string_bytes
        ).freeze
        LIMIT_KEY_NAMES = LIMIT_KEYS.map(&:to_s).freeze
        private_constant :KEYS, :METADATA_KEYS, :METADATA_KEY_NAMES, :LIMIT_KEYS, :LIMIT_KEY_NAMES

        class << self
          def build(fields, max_array_items:, max_depth:, max_hash_keys:, max_string_bytes:, key_style: :string,
                    compact_limits: false, freeze_values: false)
            keys = KEYS.fetch(key_style)
            limits = limits_hash(
              keys,
              max_array_items: max_array_items,
              max_depth: max_depth,
              max_hash_keys: max_hash_keys,
              max_string_bytes: max_string_bytes,
              compact_limits: compact_limits
            )
            metadata = {
              keys.fetch(:truncated) => true,
              keys.fetch(:truncated_fields) => field_list(fields),
              keys.fetch(:limits) => limits
            }
            freeze_values ? deep_freeze(metadata, keys) : metadata
          end

          def append_field(fields, field)
            fields ||= []
            fields << field unless fields.include?(field)
            fields
          end

          def valid?(value)
            return false unless value.is_a?(Hash)
            return false unless valid_top_level_keys?(value)
            return false unless fetch_key(value, :truncated) == true

            fields = fetch_key(value, :truncated_fields)
            limits = fetch_key(value, :limits)
            valid_fields?(fields) && valid_limits?(limits)
          end

          private

          def field_list(fields)
            Array(fields).uniq
          end

          def limits_hash(keys, max_array_items:, max_depth:, max_hash_keys:, max_string_bytes:, compact_limits:)
            limits = {
              keys.fetch(:max_array_items) => max_array_items,
              keys.fetch(:max_depth) => max_depth,
              keys.fetch(:max_hash_keys) => max_hash_keys,
              keys.fetch(:max_string_bytes) => max_string_bytes
            }
            compact_limits ? limits.compact : limits
          end

          def deep_freeze(metadata, keys)
            metadata.fetch(keys.fetch(:truncated_fields)).each(&:freeze)
            metadata.fetch(keys.fetch(:truncated_fields)).freeze
            metadata.fetch(keys.fetch(:limits)).freeze
            metadata.freeze
          end

          def fetch_key(value, key)
            return value[key] if value.key?(key)

            value[key.to_s]
          end

          def valid_top_level_keys?(value)
            value.keys.all? { known_key?(it, METADATA_KEYS, METADATA_KEY_NAMES) } &&
              METADATA_KEYS.all? { value.key?(it) || value.key?(it.to_s) }
          end

          def valid_fields?(fields)
            fields.is_a?(Array) && fields.all? { it.is_a?(String) || it.is_a?(Symbol) }
          end

          def valid_limits?(limits)
            return false unless limits.is_a?(Hash)

            limits.all? do |key, value|
              known_key?(key, LIMIT_KEYS, LIMIT_KEY_NAMES) && (value.nil? || value.is_a?(Integer))
            end
          end

          def known_key?(key, symbol_keys, string_keys)
            symbol_keys.include?(key) || string_keys.include?(key)
          end
        end
      end
      private_constant :TruncationMetadata
    end
  end
end
