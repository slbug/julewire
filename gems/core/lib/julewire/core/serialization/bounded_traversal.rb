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
            max_string_bytes: DEFAULT_MAX_STRING_BYTES,
            key_style: :string
          )
            TruncationMetadata.build(
              fields,
              key_style: key_style,
              max_array_items: max_array_items,
              max_depth: max_depth,
              max_hash_keys: max_hash_keys,
              max_string_bytes: max_string_bytes
            )
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
        end

        private

        def walk(value)
          traverse(value) { |root, depth| walk_value(root, depth, nil, nil) }
        ensure
          @last_truncated = false
        end

        def walk_value(value, depth, key, path)
          value = prepare_value(value, depth, key, path) if @prepare_values
          return max_depth_value if depth == @max_depth
          return walk_container(value, depth, path) if value.is_a?(Array) || hash_like?(value)

          scalar_value(value, depth)
        rescue StandardError => e
          error_value(e)
        end

        def hash_like?(value) = value.is_a?(Hash)

        def scalar_value(value, _depth)
          value.is_a?(String) ? string_value(value) : value
        end

        # Transform-stage errors must bubble so processors can fail closed.
        def error_value(_error)
          raise
        end

        def walk_container(value, depth, path)
          seen = traversal_seen
          return circular_value if seen.include?(value)

          seen.add(value)
          begin
            value.is_a?(Array) ? walk_array(value, depth, path) : walk_hash(value, depth, path)
          ensure
            seen.delete(value)
          end
        end

        def circular_value
          @last_truncated = true
          CIRCULAR_REFERENCE
        end

        def max_depth_value
          mark_truncated(copy_string(@max_depth_value))
        end

        def walk_hash(value, depth, path)
          return walk_compact_hash(value, depth) if @compact_empty

          walk_full_hash(value, depth, path)
        end

        def walk_full_hash(value, depth, path)
          fields = nil
          result = {}
          track_paths = @track_paths
          visited = 0
          value.each do |raw_key, item|
            if visited == @max_hash_keys
              fields = append_truncation_field(fields, "hash_keys")
              break
            end

            visited += 1
            child_path = path_for(path, raw_key) if track_paths
            child = walk_value(item, depth + 1, raw_key, child_path)
            key = key_value(raw_key)
            result[key] = child
            fields = record_hash_truncation(fields, key, consume_truncated)
          end
          finish_hash(result, fields)
        end

        def walk_compact_hash(value, depth)
          fields = nil
          result = {}
          visited = 0
          value.each do |raw_key, item|
            # The hash cap bounds visited input entries, not final output keys, so
            # serialized-key collisions and compacted entries cannot hide work.
            if visited == @max_hash_keys
              fields = append_truncation_field(fields, "hash_keys")
              break
            end

            visited += 1
            next if raw_omitted_value?(item)

            child = walk_value(item, depth + 1, nil, nil)
            next if omitted_value?(child)

            key = key_value(raw_key)
            result[key] = child
            fields = record_hash_truncation(fields, key, consume_truncated)
          end
          finish_hash(result, fields)
        end

        def walk_array(value, depth, path)
          return walk_compact_array(value, depth) if @compact_empty

          walk_full_array(value, depth, path)
        end

        def walk_full_array(value, depth, path)
          truncated = false
          result = []
          visited = 0
          value.each do |item|
            if visited == @max_array_items
              truncated = true
              break
            end

            visited += 1
            child = walk_value(item, depth + 1, nil, path)
            child_truncated = consume_truncated
            result << child
            truncated = true if child_truncated
          end
          finish_array(result, truncated && "array_items")
        end

        def walk_compact_array(value, depth)
          truncated = false
          result = []
          visited = 0
          value.each do |item|
            if visited == @max_array_items
              truncated = true
              break
            end

            visited += 1
            next if raw_omitted_value?(item)

            child = walk_value(item, depth + 1, nil, nil)
            child_truncated = consume_truncated
            next if omitted_value?(child)

            result << child
            truncated = true if child_truncated
          end
          finish_array(result, truncated && "array_items")
        end

        def key_value(key) = key

        def record_hash_truncation(fields, key, truncated)
          return fields unless truncated

          append_truncation_field(fields, key.to_s)
        end

        def finish_hash(result, fields)
          return result unless fields

          result[@truncation_key] = truncation_metadata(fields) if @truncation_key
          mark_truncated(result)
        end

        def finish_array(result, fields)
          return result unless fields

          result << { @truncation_key => truncation_metadata(fields) } if @truncation_key
          mark_truncated(result)
        end

        def truncation_metadata(fields, key_style: :string)
          self.class.truncation_metadata(
            fields,
            key_style: key_style,
            max_array_items: @max_array_items,
            max_depth: @max_depth,
            max_hash_keys: @max_hash_keys,
            max_string_bytes: @max_string_bytes
          )
        end

        def string_value(value)
          return copy_string(value) if value.bytesize <= @max_string_bytes

          mark_truncated("#{value.byteslice(0, @max_string_bytes).scrub("?")}#{TRUNCATED_SUFFIX}")
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

        def copy_string(value)
          value.is_a?(String) && !value.frozen? ? value.dup : value
        end

        def append_truncation_field(fields, field)
          TruncationMetadata.append_field(fields, field)
        end

        def path_for(parent_path, key)
          parent_path ? "#{parent_path}.#{key}" : key.to_s
        end
      end

      private_constant :BoundedTraversal
    end
  end
end
