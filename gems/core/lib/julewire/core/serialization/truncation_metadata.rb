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
        private_constant :KEYS

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
        end
      end
      private_constant :TruncationMetadata
    end
  end
end
