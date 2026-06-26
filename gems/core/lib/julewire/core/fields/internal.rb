# frozen_string_literal: true

module Julewire
  module Core
    module Fields
      module Internal
        EMPTY_ARRAY = [].freeze
        EMPTY_HASH = {}.freeze
        private_constant :EMPTY_ARRAY, :EMPTY_HASH

        class << self
          def normalize_key(key)
            key.is_a?(String) ? key.to_sym : key
          end

          def delete_key!(target, key)
            target.delete(normalize_key(key))
          end

          def frozen_copy(value)
            frozen_copy_with(value, preserve_truncation_metadata: false)
          end

          def frozen_owned_copy(value)
            frozen_copy_with(value, preserve_truncation_metadata: true)
          end

          def frozen_deep_symbolize_keys(value)
            frozen_deep_symbolize_keys_with(value, preserve_truncation_metadata: false)
          end

          def frozen_deep_symbolize_owned_keys(value)
            frozen_deep_symbolize_keys_with(value, preserve_truncation_metadata: true)
          end

          def delete_path!(target, path) = Deletion.delete_path!(target, path)

          def apply_delete_paths!(target, paths) = Deletion.apply_delete_paths!(target, paths)

          def clear_delete_paths!(paths, fields) = Deletion.clear_delete_paths!(paths, fields)

          def normalize_path(path) = Deletion.normalize_path(path)

          def deep_merge(left, right)
            deep_merge!(FieldSet.deep_symbolize_keys(left), right)
          end

          def deep_merge!(target, fields)
            merge_values!(target, fields) do |value, existing|
              if existing.is_a?(Hash) && value.is_a?(Hash)
                deep_merge!(existing, value)
              else
                FieldSet.deep_symbolize_keys(value)
              end
            end
          end

          def deep_merge_owned!(target, fields)
            merge_values!(target, fields) do |value, existing|
              if existing.is_a?(Hash) && value.is_a?(Hash)
                deep_merge_owned!(existing, value)
              else
                value
              end
            end
          end

          def merge_owned!(target, fields)
            merge_values!(target, fields) { |value, _existing| value }
          end

          private

          def frozen_copy_with(value, preserve_truncation_metadata:)
            return EMPTY_HASH if value.is_a?(Hash) && value.empty?
            return EMPTY_ARRAY if value.is_a?(Array) && value.empty?

            Serialization::ValueCopy.call(
              value,
              freeze_values: true,
              preserve_truncation_metadata: preserve_truncation_metadata
            )
          end

          def frozen_deep_symbolize_keys_with(value, preserve_truncation_metadata:)
            return EMPTY_HASH if value.is_a?(Hash) && value.empty?
            return EMPTY_ARRAY if value.is_a?(Array) && value.empty?

            Serialization::ValueCopy.call(
              value,
              freeze_values: true,
              max_array_items: Serialization::Serializer::DEFAULT_MAX_ARRAY_ITEMS,
              max_hash_keys: Serialization::Serializer::DEFAULT_MAX_HASH_KEYS,
              max_string_bytes: Serialization::Serializer::DEFAULT_MAX_STRING_BYTES,
              preserve_truncation_metadata: preserve_truncation_metadata,
              symbolize_keys: true
            )
          end

          def merge_values!(target, fields)
            return target unless fields.is_a?(Hash)

            fields.each do |key, value|
              normalized_key = normalize_key(key)
              existing = target[normalized_key]
              target[normalized_key] = yield value, existing
            end

            target
          end
        end
      end
    end
  end
end
