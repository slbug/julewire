# frozen_string_literal: true

module Julewire
  module Core
    module Serialization
      module TruncationMetadata
        NAMES = %i[truncated truncated_fields limits max_array_items max_depth max_hash_keys max_string_bytes].freeze
        KEYS = {
          string: NAMES.to_h { [it, it.to_s] }.freeze,
          symbol: NAMES.to_h { [it, it] }.freeze
        }.freeze
        METADATA_KEYS = KEYS.fetch(:symbol).values_at(:truncated, :truncated_fields, :limits).freeze
        METADATA_KEY_NAMES = KEYS.fetch(:string).values_at(:truncated, :truncated_fields, :limits).freeze
        LIMIT_KEYS = KEYS.fetch(:symbol).values_at(
          :max_array_items,
          :max_depth,
          :max_hash_keys,
          :max_string_bytes
        ).freeze
        LIMIT_KEY_NAMES = KEYS.fetch(:string).values_at(
          :max_array_items,
          :max_depth,
          :max_hash_keys,
          :max_string_bytes
        ).freeze
        SYMBOL_METADATA_KEYS = KEYS.fetch(:symbol).merge(limit_keys: LIMIT_KEYS).freeze
        STRING_METADATA_KEYS = KEYS.fetch(:string).merge(limit_keys: LIMIT_KEY_NAMES).freeze
        [
          NAMES,
          KEYS,
          METADATA_KEYS,
          METADATA_KEY_NAMES,
          LIMIT_KEYS,
          LIMIT_KEY_NAMES,
          SYMBOL_METADATA_KEYS,
          STRING_METADATA_KEYS
        ].each do |constant|
          ::Ractor.make_shareable(constant) if defined?(::Ractor) && ::Ractor.respond_to?(:make_shareable)
        end
        private_constant :NAMES, :KEYS, :METADATA_KEYS, :METADATA_KEY_NAMES, :LIMIT_KEYS, :LIMIT_KEY_NAMES,
                         :SYMBOL_METADATA_KEYS, :STRING_METADATA_KEYS

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

          def valid?(value, max_fields: nil)
            return false unless value.is_a?(Hash)

            keys = metadata_keys(value)
            return false unless keys
            return false unless value.fetch(keys.fetch(:truncated)) == true

            valid_fields?(value.fetch(keys.fetch(:truncated_fields)), max_fields: max_fields) &&
              valid_limits?(value.fetch(keys.fetch(:limits)), limit_keys: keys.fetch(:limit_keys))
          end

          def copy(value, freeze_values:, key_style: :symbol)
            source_keys = metadata_keys(value)
            target_keys = KEYS.fetch(key_style)
            metadata = {
              target_keys.fetch(:truncated) => true,
              target_keys.fetch(:truncated_fields) => copy_fields(value.fetch(source_keys.fetch(:truncated_fields))),
              target_keys.fetch(:limits) => copy_limits(value.fetch(source_keys.fetch(:limits)), source_keys,
                                                        target_keys)
            }
            freeze_values ? deep_freeze(metadata, target_keys) : metadata
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

          def copy_fields(fields)
            fields.map(&:dup)
          end

          def copy_limits(limits, source_keys, target_keys)
            LIMIT_KEYS.each_with_object({}) do |name, copied|
              source_key = source_keys.fetch(name)
              next unless limits.key?(source_key)

              copied[target_keys.fetch(name)] = limits.fetch(source_key)
            end
          end

          def metadata_keys(value)
            return SYMBOL_METADATA_KEYS if exact_keys?(value, METADATA_KEYS)

            STRING_METADATA_KEYS if exact_keys?(value, METADATA_KEY_NAMES)
          end

          def exact_keys?(value, keys)
            value.length == keys.length && keys.all? { value.key?(it) }
          end

          def valid_fields?(fields, max_fields:)
            return false unless fields.is_a?(Array)
            return false if max_fields && fields.length > max_fields

            fields.all?(String)
          end

          def valid_limits?(limits, limit_keys:)
            return false unless limits.is_a?(Hash)

            limits.all? do |key, value|
              limit_keys.include?(key) && (value.nil? || value.instance_of?(Integer))
            end
          end
        end
      end
      private_constant :TruncationMetadata
    end
  end
end
