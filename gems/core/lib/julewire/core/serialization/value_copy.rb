# frozen_string_literal: true

module Julewire
  module Core
    module Serialization
      module ValueCopyTruncation
        private

        def validate_optional_limit(value, name:)
          return unless value

          Validation.validate_integer_limit!(value, name: name)
        end

        def finish_hash(result, fields)
          add_truncation_metadata!(result, fields)
          finish_container(result, fields)
        end

        def finish_array(result, fields)
          if @track_truncation && fields
            result << freeze_container({ Serializer::TRUNCATION_METADATA_KEY.to_sym => truncation_metadata(fields) })
          end
          finish_container(result, fields)
        end

        def add_truncation_metadata!(result, fields)
          return unless @track_truncation && fields

          result[Serializer::TRUNCATION_METADATA_KEY.to_sym] = truncation_metadata(fields)
        end

        def finish_container(result, fields)
          value = freeze_container(result)
          fields ? mark_truncated(value) : value
        end

        def truncation_metadata(fields)
          TruncationMetadata.build(
            fields,
            key_style: :symbol,
            compact_limits: true,
            freeze_values: @freeze_values,
            max_array_items: @max_array_items,
            max_depth: @max_depth,
            max_hash_keys: @max_hash_keys,
            max_string_bytes: @max_string_bytes
          )
        end

        def mark_truncated(value)
          @last_truncated = true
          value
        end

        def consume_truncated
          truncated = @last_truncated
          @last_truncated = false
          truncated
        end

        def append_truncation_field(fields, field)
          TruncationMetadata.append_field(fields, field)
        end
      end
      private_constant :ValueCopyTruncation

      class ValueCopy
        include ValueTraversal
        include ValueCopyTruncation

        CIRCULAR_REFERENCE = Core::CIRCULAR_REFERENCE
        EMPTY_ARRAY = [].freeze
        EMPTY_HASH = {}.freeze
        private_constant :EMPTY_ARRAY, :EMPTY_HASH

        class << self
          def call( # rubocop:disable Metrics/ParameterLists
            value,
            compact_empty: false,
            freeze_values: false,
            max_array_items: nil,
            max_depth: NORMALIZATION_MAX_DEPTH,
            max_hash_keys: nil,
            max_string_bytes: nil,
            preserve_truncation_metadata: false,
            symbolize_keys: false
          )
            new(
              compact_empty:,
              freeze_values:,
              max_array_items:,
              max_depth:,
              max_hash_keys:,
              max_string_bytes:,
              preserve_truncation_metadata:,
              symbolize_keys:
            ).call(value)
          end

          def omitted_empty?(value)
            value.nil? || (value.is_a?(Hash) && value.empty?) || (value.is_a?(Array) && value.empty?)
          end
        end

        def initialize(compact_empty:, freeze_values:, max_array_items:, max_depth:, max_hash_keys:, max_string_bytes:,
                       preserve_truncation_metadata:, symbolize_keys:)
          @compact_empty = compact_empty
          @freeze_values = freeze_values
          @max_array_items = validate_optional_limit(max_array_items, name: :max_array_items)
          @max_depth = max_depth
          @max_hash_keys = validate_optional_limit(max_hash_keys, name: :max_hash_keys)
          @max_string_bytes = validate_optional_limit(max_string_bytes, name: :max_string_bytes)
          @preserve_truncation_metadata = preserve_truncation_metadata
          @symbolize_keys = symbolize_keys
          @track_truncation = @max_array_items || @max_hash_keys || @max_string_bytes
        end

        def call(value)
          traverse(value) { |root, depth| copy_value(root, depth) }
        end

        private

        def copy_value(value, depth)
          return copy_container(value, depth) if value.is_a?(Hash) || value.is_a?(Array)
          return copy_string(value) if value.is_a?(String)
          return copy_time(value) if value.is_a?(Time)

          value
        end

        def copy_container(value, depth)
          return mark_truncated(Serializer::MAX_DEPTH_VALUE) if depth == @max_depth
          return frozen_empty_container(value) if @freeze_values && value.empty?

          with_traversal_container(value, CIRCULAR_REFERENCE) do
            value.is_a?(Hash) ? copy_hash(value, depth) : copy_array(value, depth)
          end
        end

        def frozen_empty_container(value)
          value.is_a?(Hash) ? EMPTY_HASH : EMPTY_ARRAY
        end

        def copy_hash(value, depth)
          fields = nil
          result = {}
          visited = 0
          value.each do |key, item|
            if visited == @max_hash_keys
              fields = append_truncation_field(fields, "hash_keys")
              break
            end

            visited += 1
            next if @compact_empty && self.class.omitted_empty?(item)

            fields = copy_hash_entry(result, fields, key, item, depth)
          end
          finish_hash(result, fields)
        end

        def copy_hash_entry(result, fields, key, item, depth)
          return copy_truncation_metadata_entry(result, fields, key, item) if reserved_truncation_key?(key)

          validate_symbolized_key_shape!(key)
          copied = copy_value(item, depth + 1)
          return fields if @compact_empty && self.class.omitted_empty?(copied)

          copied_key = copied_key_value(key)
          value_or_key_truncated = consume_truncated
          result[copied_key] = copied
          fields = append_truncation_field(fields, copied_key.to_s) if value_or_key_truncated
          fields
        end

        def copy_truncation_metadata_entry(result, fields, key, item)
          unless @preserve_truncation_metadata &&
                 allowed_truncation_metadata_key?(key) &&
                 TruncationMetadata.valid?(item, max_fields: truncation_metadata_field_limit)
            raise_reserved_key!
          end

          result[copy_truncation_metadata_key(key)] = TruncationMetadata.copy(
            item,
            freeze_values: @freeze_values
          )
          fields
        end

        def truncation_metadata_field_limit
          @max_array_items || Serializer::DEFAULT_MAX_ARRAY_ITEMS
        end

        def allowed_truncation_metadata_key?(key)
          key.instance_of?(Symbol) || @symbolize_keys
        end

        def reserved_truncation_key?(key)
          key == Serializer::TRUNCATION_METADATA_KEY || key == Serializer::TRUNCATION_METADATA_KEY.to_sym
        end

        def copy_truncation_metadata_key(key)
          key.to_sym
        end

        def validate_symbolized_key_shape!(key)
          return unless @symbolize_keys
          return if key.is_a?(String) || key.instance_of?(Symbol)

          raise TypeError, Fields::Internal::FIELD_KEY_ERROR
        end

        def copy_array(value, depth)
          result = []
          visited = 0
          array_items_truncated = false
          array_item_values_truncated = false
          value.each do |item|
            if visited == @max_array_items
              array_items_truncated = true
              break
            end

            visited += 1
            next if @compact_empty && self.class.omitted_empty?(item)

            copied = copy_value(item, depth + 1)
            child_truncated = consume_truncated
            next if @compact_empty && self.class.omitted_empty?(copied)

            result << copied
            array_item_values_truncated ||= child_truncated
          end

          finish_array(result, array_truncation_fields(array_items_truncated, array_item_values_truncated))
        end

        def array_truncation_fields(array_items_truncated, array_item_values_truncated)
          return unless array_items_truncated || array_item_values_truncated

          fields = []
          fields << "array_item_values" if array_item_values_truncated
          fields << "array_items" if array_items_truncated
          fields
        end

        def copied_key_value(key)
          return key unless key.is_a?(String)

          copy = copy_string(key)
          @symbolize_keys ? copy.to_sym : copy
        end

        def raise_reserved_key!
          raise ArgumentError, "#{Serializer::TRUNCATION_METADATA_KEY} is reserved for Julewire truncation metadata"
        end

        def copy_string(value)
          if @max_string_bytes && value.bytesize > @max_string_bytes
            copy = "#{value.byteslice(0, @max_string_bytes).scrub("?")}#{Serializer::TRUNCATED_SUFFIX}"
            return mark_truncated(freeze_container(copy))
          end

          copy = value.frozen? ? value : value.dup
          freeze_container(copy)
        end

        def copy_time(value)
          return value unless @freeze_values
          return value if value.frozen?

          value.dup.freeze
        end

        def freeze_container(value)
          @freeze_values ? value.freeze : value
        end
      end
    end
  end
end
