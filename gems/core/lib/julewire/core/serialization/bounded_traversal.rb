# frozen_string_literal: true

module Julewire
  module Core
    module Serialization
      class BoundedTraversal
        include ValueTraversal

        MAX_DEPTH_VALUE = "[MaxDepth]"
        TRUNCATED_SUFFIX = "...[Truncated]"
        TRUNCATION_METADATA_KEY = "_julewire_truncation"
        DEFAULT_MAX_DEPTH = 8
        DEFAULT_MAX_STRING_BYTES = 16_384
        DEFAULT_MAX_ARRAY_ITEMS = 1_000
        DEFAULT_MAX_HASH_KEYS = 1_000

        class << self
          def truncation_metadata(
            fields,
            max_array_items: DEFAULT_MAX_ARRAY_ITEMS,
            max_depth: DEFAULT_MAX_DEPTH,
            max_hash_keys: DEFAULT_MAX_HASH_KEYS,
            max_string_bytes: DEFAULT_MAX_STRING_BYTES
          )
            {
              "truncated" => true,
              "truncated_fields" => Array(fields).uniq,
              "limits" => {
                "max_array_items" => max_array_items,
                "max_depth" => max_depth,
                "max_hash_keys" => max_hash_keys,
                "max_string_bytes" => max_string_bytes
              }
            }
          end
        end

        def initialize(max_array_items:, max_depth:, max_depth_value:, max_hash_keys:, max_string_bytes:,
                       truncation_key:)
          @max_array_items = Validation.validate_integer_limit!(max_array_items, name: :max_array_items)
          @max_depth = Validation.validate_integer_limit!(max_depth, name: :max_depth, positive: true)
          @max_depth_value = max_depth_value
          @max_hash_keys = Validation.validate_integer_limit!(max_hash_keys, name: :max_hash_keys)
          @max_string_bytes = Validation.validate_integer_limit!(max_string_bytes, name: :max_string_bytes)
          @truncation_key = truncation_key
          @last_truncated = false
          @compact_empty = false
          @prepare_values = false
          @track_paths = false
        end

        private

        def walk(value)
          @last_truncated = false
          traverse(value) { |root, depth| walk_value(root, depth, nil, nil) }
        ensure
          @last_truncated = false
        end

        def walk_value(value, depth, key, path)
          @last_truncated = false
          value = prepare_value(value, depth, key, path) if @prepare_values
          return max_depth_value if depth >= @max_depth
          return walk_container(value, depth, path) if value.is_a?(Array) || hash_like?(value)

          scalar_value(value, depth, key, path)
        rescue StandardError => e
          @last_truncated = false
          error_value(e)
        end

        def prepare_value(value, _depth, _key, _path) = value

        def hash_like?(value) = value.is_a?(Hash)

        def scalar_value(value, _depth, _key, _path)
          value.is_a?(String) ? string_value(value) : clear_truncated(value)
        end

        # Transform-stage errors must bubble so processors can fail closed.
        def error_value(error)
          raise error
        end

        def walk_container(value, depth, path)
          return circular_value if traversal_seen?(value)

          with_marked_traversal_container(value) do
            value.is_a?(Array) ? walk_array(value, depth, path) : walk_hash(value, depth, path)
          end
        end

        def circular_value
          @last_truncated = true
          Core::CIRCULAR_REFERENCE
        end

        def max_depth_value
          mark_truncated(copy_string(@max_depth_value))
        end

        def walk_hash(value, depth, path)
          return walk_compact_hash(value, depth, path) if @compact_empty

          walk_full_hash(value, depth, path)
        end

        def walk_full_hash(value, depth, path)
          fields = nil
          result = {}
          track_paths = @track_paths
          value.each do |raw_key, item|
            if result.length >= @max_hash_keys
              fields = append_truncation_field(fields, "hash_keys")
              break
            end

            child = walk_value(item, depth + 1, raw_key, track_paths ? path_for(path, raw_key) : nil)
            child_truncated = consume_truncated
            key = key_value(raw_key)
            key_truncated = consume_truncated
            result[key] = child
            fields = record_hash_truncation(fields, raw_key, key, key_truncated, child_truncated)
          end
          finish_hash(result, fields)
        end

        def walk_compact_hash(value, depth, path)
          fields = nil
          result = {}
          track_paths = @track_paths
          value.each do |raw_key, item|
            next if raw_omitted_value?(item)

            child = walk_value(item, depth + 1, raw_key, track_paths ? path_for(path, raw_key) : nil)
            child_truncated = consume_truncated
            next if omitted_value?(child)

            if result.length >= @max_hash_keys
              fields = append_truncation_field(fields, "hash_keys")
              break
            end

            key = key_value(raw_key)
            key_truncated = consume_truncated
            result[key] = child
            fields = record_hash_truncation(fields, raw_key, key, key_truncated, child_truncated)
          end
          finish_hash(result, fields)
        end

        def walk_array(value, depth, path)
          return walk_compact_array(value, depth, path) if @compact_empty

          walk_full_array(value, depth, path)
        end

        def walk_full_array(value, depth, path)
          fields = nil
          result = []
          value.each do |item|
            if result.length >= @max_array_items
              fields = append_truncation_field(fields, "array_items")
              break
            end

            child = walk_value(item, depth + 1, nil, path)
            child_truncated = consume_truncated
            result << child
            fields = append_truncation_field(fields, "array_items") if child_truncated
          end
          finish_array(result, fields)
        end

        def walk_compact_array(value, depth, path)
          fields = nil
          result = []
          value.each do |item|
            next if raw_omitted_value?(item)

            child = walk_value(item, depth + 1, nil, path)
            child_truncated = consume_truncated
            next if omitted_value?(child)

            if result.length >= @max_array_items
              fields = append_truncation_field(fields, "array_items")
              break
            end

            result << child
            fields = append_truncation_field(fields, "array_items") if child_truncated
          end
          finish_array(result, fields)
        end

        def omitted_value?(_value) = false

        def raw_omitted_value?(_value) = false

        def key_value(key)
          clear_truncated(key.is_a?(String) ? copy_string(key) : key)
        end

        def record_hash_truncation(fields, raw_key, _key, _key_truncated, child_truncated)
          return fields unless child_truncated

          append_truncation_field(fields, raw_key.to_s)
        end

        def finish_hash(result, fields)
          return clear_truncated(result) unless fields

          result[@truncation_key] = truncation_metadata(fields) if @truncation_key
          mark_truncated(result)
        end

        def finish_array(result, fields)
          return clear_truncated(result) unless fields

          result << { @truncation_key => truncation_metadata(fields) } if @truncation_key
          mark_truncated(result)
        end

        def truncation_metadata(fields)
          self.class.truncation_metadata(
            fields,
            max_array_items: @max_array_items,
            max_depth: @max_depth,
            max_hash_keys: @max_hash_keys,
            max_string_bytes: @max_string_bytes
          )
        end

        def string_value(value)
          return clear_truncated(copy_string(value)) if value.bytesize <= @max_string_bytes

          mark_truncated("#{value.byteslice(0, @max_string_bytes).scrub("?")}#{TRUNCATED_SUFFIX}")
        end

        def mark_truncated(value)
          @last_truncated = true
          value
        end

        def clear_truncated(value)
          @last_truncated = false
          value
        end

        def consume_truncated
          truncated = @last_truncated
          @last_truncated = false
          truncated
        end

        def copy_string(value)
          value.is_a?(String) && !value.frozen? ? value.dup : value
        end

        def append_truncation_field(fields, field)
          (fields ||= []) << field
          fields
        end

        def path_for(parent_path, key)
          parent_path ? "#{parent_path}.#{key}" : key.to_s
        end
      end

      private_constant :BoundedTraversal
    end
  end
end
