# frozen_string_literal: true

module Julewire
  module Redaction
    class Processor
      PRESERVED_TOP_LEVEL_KEYS = (
        Core::Fields::Bags.record_scalar_keys - %i[message]
      ).freeze
      private_constant :PRESERVED_TOP_LEVEL_KEYS

      def initialize(
        filters = Redaction.config.filters,
        mask: Redaction.config.mask,
        max_array_items: Redaction.config.max_array_items,
        max_depth: Redaction.config.max_depth,
        max_hash_keys: Redaction.config.max_hash_keys,
        max_string_bytes: Redaction.config.max_string_bytes,
        string_values: Redaction.config.string_values,
        authorization_header: Redaction.config.authorization_header
      )
        @matcher = Matcher.new(filters)
        @blocks = @matcher.blocks
        @mask = mask.to_s
        @max_array_items = Core::Validation.validate_integer_limit!(max_array_items, name: :max_array_items)
        @max_depth = Core::Validation.validate_integer_limit!(max_depth, name: :max_depth, positive: true)
        @max_hash_keys = Core::Validation.validate_integer_limit!(max_hash_keys, name: :max_hash_keys)
        @max_string_bytes = Core::Validation.validate_integer_limit!(max_string_bytes, name: :max_string_bytes)
        @string_redactor = if string_values
                             StringRedactor.new(
                               matcher: @matcher,
                               mask: @mask,
                               authorization_header: authorization_header
                             )
                           end
        @redact_keys = !@matcher.empty?
        @redact_scalars = @string_redactor || !@blocks.empty?
        @enabled = @redact_keys || @redact_scalars
        @record_transform = Core::Processing::RecordFieldTransform.new(
          max_array_items: @max_array_items,
          max_depth: @max_depth,
          max_hash_keys: @max_hash_keys,
          max_string_bytes: @max_string_bytes,
          preserve_top_level_keys: PRESERVED_TOP_LEVEL_KEYS,
          track_paths: @matcher.path_dependent?
        )
      end

      def call(draft)
        validate_draft!(draft)
        return draft unless @enabled

        draft.transform_record! { redact_record(it) }
      end

      private

      def validate_draft!(draft)
        return if draft.instance_of?(Julewire::RecordDraft)

        raise TypeError, "expected Julewire::RecordDraft"
      end

      def redact_record(record)
        @record_transform.call(record) do |item, key:, path:, prefixed_path:, original:, **|
          redact_item(
            item,
            key: key,
            path: path,
            prefixed_path: prefixed_path,
            original: original
          )
        end
      end

      def redact_item(item, key:, path:, original:, prefixed_path:, **)
        return @mask if redacted_key?(key, path: path, prefixed_path: prefixed_path)
        if @redact_scalars && !item.is_a?(Hash) && !item.is_a?(Array)
          return redact_scalar(item, key: key, original: original)
        end

        Core::Serialization::BoundedTransform::CONTINUE
      end

      def redacted_key?(key, path:, prefixed_path:)
        return false unless @redact_keys && key
        return true if @matcher.match?(key, path: path)

        prefixed_path && @matcher.match?(key, path: prefixed_path)
      end

      def redact_scalar(value, key:, original:)
        value = apply_block_filters(key, value, original) if key && !@blocks.empty?
        value.is_a?(String) && @string_redactor ? @string_redactor.call(value) : value
      end

      def apply_block_filters(key, value, original)
        key_copy = key.to_s.dup
        value_copy = duplicate_filter_value(value)
        @blocks.each do |block|
          block.arity == 2 ? block.call(key_copy, value_copy) : block.call(key_copy, value_copy, original)
        end
        value_copy
      end

      def duplicate_filter_value(value)
        value.is_a?(String) ? value.dup : value
      end
    end
  end
end
