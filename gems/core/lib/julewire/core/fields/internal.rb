# frozen_string_literal: true

module Julewire
  module Core
    module Fields
      module Internal
        FIELD_KEY_ERROR = "field keys must be String or Symbol"
        RECORD_STRING_KEY_ERROR = "record must not use string keys"
        RECORD_SYMBOL_KEY_ERROR = "record keys must be Symbols"

        class << self
          def normalize_key(key)
            return key.to_sym if key.is_a?(String)
            return key if key.instance_of?(Symbol)

            raise TypeError, FIELD_KEY_ERROR
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

          def apply_delete_paths!(target, paths) = Deletion.apply_delete_paths!(target, paths)

          def clear_delete_paths!(paths, fields) = Deletion.clear_delete_paths!(paths, fields)

          def normalize_path(path) = Deletion.normalize_path(path)

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
            merge_owned_values!(target, fields) do |value, existing|
              if existing.is_a?(Hash) && value.is_a?(Hash)
                deep_merge_owned!(existing, value)
              else
                value
              end
            end
          end

          def merge_owned!(target, fields)
            merge_owned_values!(target, fields) { |value, _existing| value }
          end

          private

          def frozen_copy_with(value, preserve_truncation_metadata:)
            Serialization::ValueCopy.call(
              value,
              freeze_values: true,
              preserve_truncation_metadata: preserve_truncation_metadata
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

          def merge_owned_values!(target, fields)
            return target unless fields.is_a?(Hash)

            fields.each do |key, value|
              target[key] = yield value, target[key]
            end

            target
          end
        end
      end
    end
  end
end
