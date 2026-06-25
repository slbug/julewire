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

        def record_hash_truncation(fields, key, truncated)
          return fields unless truncated

          append_truncation_field(fields, key.to_s)
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
          fields ? mark_truncated(value) : clear_truncated(value)
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

        def clear_truncated(value)
          @last_truncated = false
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

      module ValueCopyCache
        POOL_KEY = :julewire_core_value_copy_pool
        private_constant :POOL_KEY

        private

        def cached_copier(compact_empty:, freeze_values:, max_array_items:, max_depth:, max_hash_keys:,
                          max_string_bytes:, symbolize_keys:)
          options = copier_options(
            compact_empty: compact_empty,
            freeze_values: freeze_values,
            max_array_items: max_array_items,
            max_depth: max_depth,
            max_hash_keys: max_hash_keys,
            max_string_bytes: max_string_bytes,
            symbolize_keys: symbolize_keys
          )
          return new(**options) unless cacheable_options?(options)

          reusable_copier(options)
        end

        def reusable_copier(options)
          # One copier per thread/options avoids per-record walker allocation.
          pool = Thread.current.thread_variable_get(POOL_KEY)
          unless pool
            pool = {}
            Thread.current.thread_variable_set(POOL_KEY, pool)
          end

          bucket = cache_bucket(
            pool,
            compact_empty: options.fetch(:compact_empty),
            freeze_values: options.fetch(:freeze_values),
            max_array_items: options.fetch(:max_array_items),
            max_depth: options.fetch(:max_depth),
            max_hash_keys: options.fetch(:max_hash_keys),
            symbolize_keys: options.fetch(:symbolize_keys)
          )
          bucket[options.fetch(:max_string_bytes)] ||= new(**options)
        end

        def copier_options(compact_empty:, freeze_values:, max_array_items:, max_depth:, max_hash_keys:,
                           max_string_bytes:, symbolize_keys:)
          {
            compact_empty: compact_empty,
            freeze_values: freeze_values,
            max_array_items: max_array_items,
            max_depth: max_depth,
            max_hash_keys: max_hash_keys,
            max_string_bytes: max_string_bytes,
            symbolize_keys: symbolize_keys
          }
        end

        def cache_bucket(pool, compact_empty:, freeze_values:, max_array_items:, max_depth:, max_hash_keys:,
                         symbolize_keys:)
          flags = cache_flags(
            compact_empty: compact_empty,
            freeze_values: freeze_values,
            symbolize_keys: symbolize_keys
          )
          by_depth = (pool[flags] ||= {})
          by_array = (by_depth[max_depth] ||= {})
          by_hash = (by_array[max_array_items] ||= {})
          by_hash[max_hash_keys] ||= {}
        end

        def cache_flags(compact_empty:, freeze_values:, symbolize_keys:)
          flags = 0
          flags |= 1 if compact_empty
          flags |= 2 if freeze_values
          flags |= 4 if symbolize_keys
          flags
        end

        def cacheable_options?(options)
          # Only default ingress bounds use the thread-local pool; custom limits instantiate ad hoc.
          options.fetch(:max_depth) == Core::NORMALIZATION_MAX_DEPTH &&
            [nil, Serializer::DEFAULT_MAX_ARRAY_ITEMS].include?(options.fetch(:max_array_items)) &&
            [nil, Serializer::DEFAULT_MAX_HASH_KEYS].include?(options.fetch(:max_hash_keys)) &&
            [nil, Serializer::DEFAULT_MAX_STRING_BYTES].include?(options.fetch(:max_string_bytes))
        end
      end
      private_constant :ValueCopyCache

      class ValueCopy
        include ValueTraversal
        include ValueCopyTruncation

        CIRCULAR_REFERENCE = Core::CIRCULAR_REFERENCE
        EMPTY_ARRAY = [].freeze
        EMPTY_HASH = {}.freeze
        RESERVED_KEYS = [Serializer::TRUNCATION_METADATA_KEY, Serializer::TRUNCATION_METADATA_KEY.to_sym].freeze
        private_constant :EMPTY_ARRAY, :EMPTY_HASH, :RESERVED_KEYS

        class << self
          include ValueCopyCache

          def call(
            value,
            compact_empty: false,
            freeze_values: false,
            max_array_items: nil,
            max_depth: Core::NORMALIZATION_MAX_DEPTH,
            max_hash_keys: nil,
            max_string_bytes: nil,
            symbolize_keys: false
          )
            needs_string_limit = value.is_a?(String) && max_string_bytes
            return copy_leaf(value, freeze_values: freeze_values) unless container?(value) || needs_string_limit

            copy_with(
              cached_copier(
                compact_empty: compact_empty,
                freeze_values: freeze_values,
                max_array_items: max_array_items,
                max_depth: max_depth,
                max_hash_keys: max_hash_keys,
                max_string_bytes: max_string_bytes,
                symbolize_keys: symbolize_keys
              ),
              value
            )
          end

          def omitted_empty?(value)
            value.nil? || (value.is_a?(Hash) && value.empty?) || (value.is_a?(Array) && value.empty?)
          end

          private

          def container?(value) = value.is_a?(Hash) || value.is_a?(Array)

          def copy_with(copier, value)
            return copier.call_reusable(value) unless copier.in_use?

            new(
              compact_empty: copier.compact_empty,
              freeze_values: copier.freeze_values,
              max_array_items: copier.max_array_items,
              max_depth: copier.max_depth,
              max_hash_keys: copier.max_hash_keys,
              max_string_bytes: copier.max_string_bytes,
              symbolize_keys: copier.symbolize_keys
            ).call(value)
          end

          def copy_leaf(value, freeze_values:)
            return copy_string(value, freeze_values: freeze_values) if value.is_a?(String)
            return copy_time(value, freeze_values: freeze_values) if value.is_a?(Time)

            value
          end

          def copy_string(value, freeze_values:)
            copy = value.frozen? ? value : value.dup
            freeze_values ? copy.freeze : copy
          end

          def copy_time(value, freeze_values:)
            return value unless freeze_values
            return value if value.frozen?

            value.dup.freeze
          end
        end

        attr_reader :compact_empty, :freeze_values, :max_array_items, :max_depth, :max_hash_keys, :max_string_bytes,
                    :symbolize_keys

        def initialize(compact_empty:, freeze_values:, max_array_items:, max_depth:, max_hash_keys:, max_string_bytes:,
                       symbolize_keys:)
          @compact_empty = compact_empty
          @freeze_values = freeze_values
          @max_array_items = validate_optional_limit(max_array_items, name: :max_array_items)
          @max_depth = max_depth
          @max_hash_keys = validate_optional_limit(max_hash_keys, name: :max_hash_keys)
          @max_string_bytes = validate_optional_limit(max_string_bytes, name: :max_string_bytes)
          @symbolize_keys = symbolize_keys
          @in_use = false
          @last_truncated = false
          @track_truncation = !!(@max_array_items || @max_hash_keys || @max_string_bytes)
        end

        def call(value)
          @last_truncated = false
          traverse(value) { |root, depth| copy_value(root, depth) }
        ensure
          @last_truncated = false
        end

        def call_reusable(value)
          @in_use = true
          call(value)
        ensure
          @in_use = false
        end

        def in_use? = @in_use

        private

        def copy_value(value, depth)
          return copy_container(value, depth) if value.is_a?(Hash) || value.is_a?(Array)
          return copy_string(value) if value.is_a?(String)
          return copy_time(value) if value.is_a?(Time)

          value
        end

        def copy_container(value, depth)
          return mark_truncated(copy_string(Serializer::MAX_DEPTH_VALUE)) if depth_limited?(depth)
          return frozen_empty_container(value) if @freeze_values && value.empty?

          with_traversal_container(value, CIRCULAR_REFERENCE) do
            value.is_a?(Hash) ? copy_hash(value, depth) : copy_array(value, depth)
          end
        end

        def depth_limited?(depth)
          @max_depth && depth >= @max_depth
        end

        def frozen_empty_container(value)
          value.is_a?(Hash) ? EMPTY_HASH : EMPTY_ARRAY
        end

        def copy_hash(value, depth)
          fields = nil
          result = {}
          visited = 0
          value.each do |key, item|
            if hash_limit_reached?(visited)
              fields = append_truncation_field(fields, "hash_keys")
              break
            end

            visited += 1
            # Raw-empty values still spend work budget. The limit protects traversal work, not output size.
            next if @compact_empty && self.class.omitted_empty?(item)

            fields = copy_hash_entry(result, fields, key, item, depth)
          end
          finish_hash(result, fields)
        end

        def hash_limit_reached?(visited)
          @max_hash_keys && visited >= @max_hash_keys
        end

        def copy_hash_entry(result, fields, key, item, depth)
          return copy_truncation_metadata_entry(result, fields, key, item, depth) if reserved_truncation_key?(key)

          copied = copy_value(item, depth + 1)
          child_truncated = consume_truncated
          return fields if @compact_empty && self.class.omitted_empty?(copied)

          copied_key = copy_key(key)
          key_truncated = consume_truncated
          result[copied_key] = copied
          record_hash_truncation(fields, copied_key, key_truncated || child_truncated)
        end

        def copy_truncation_metadata_entry(result, fields, key, item, depth)
          raise_reserved_key!(key) unless allowed_truncation_metadata_key?(key) && TruncationMetadata.valid?(item)

          result[copy_truncation_metadata_key(key)] = copy_value(item, depth + 1)
          consume_truncated
          fields
        end

        def allowed_truncation_metadata_key?(key)
          key.is_a?(Symbol) || @symbolize_keys
        end

        def reserved_truncation_key?(key)
          key == Serializer::TRUNCATION_METADATA_KEY || key == Serializer::TRUNCATION_METADATA_KEY.to_sym
        end

        def copy_truncation_metadata_key(key)
          @symbolize_keys && key.is_a?(String) ? key.to_sym : key
        end

        def copy_array(value, depth)
          fields = nil
          result = []
          visited = 0
          value.each do |item|
            if array_limit_reached?(visited)
              fields = append_truncation_field(fields, "array_items")
              break
            end

            visited += 1
            next if @compact_empty && self.class.omitted_empty?(item)

            fields = copy_array_item(result, fields, item, depth)
          end
          finish_array(result, fields)
        end

        def array_limit_reached?(visited)
          @max_array_items && visited >= @max_array_items
        end

        def copy_array_item(result, fields, item, depth)
          copied = copy_value(item, depth + 1)
          child_truncated = consume_truncated
          return fields if @compact_empty && self.class.omitted_empty?(copied)

          result << copied
          child_truncated ? append_truncation_field(fields, "array_item_values") : fields
        end

        def copy_key(key)
          copied = key.is_a?(String) ? copy_string(key) : key
          copied = copied.to_sym if @symbolize_keys && copied.is_a?(String)
          raise_reserved_key!(copied)

          copied
        end

        def raise_reserved_key!(key)
          return unless RESERVED_KEYS.include?(key)

          raise ArgumentError, "#{Serializer::TRUNCATION_METADATA_KEY} is reserved for Julewire truncation metadata"
        end

        def copy_string(value)
          return value unless value.is_a?(String)

          if @max_string_bytes && value.bytesize > @max_string_bytes
            copy = "#{value.byteslice(0, @max_string_bytes).scrub("?")}#{Serializer::TRUNCATED_SUFFIX}"
            return mark_truncated(freeze_container(copy))
          end

          copy = value.frozen? ? value : value.dup
          clear_truncated(freeze_container(copy))
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
