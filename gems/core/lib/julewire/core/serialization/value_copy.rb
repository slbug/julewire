# frozen_string_literal: true

module Julewire
  module Core
    module Serialization
      class ValueCopy
        include ValueTraversal

        CIRCULAR_REFERENCE = Core::CIRCULAR_REFERENCE
        EMPTY_ARRAY = [].freeze
        EMPTY_HASH = {}.freeze
        POOL_KEY = :julewire_core_value_copy_pool
        private_constant :EMPTY_ARRAY, :EMPTY_HASH, :POOL_KEY

        class << self
          def call(
            value,
            compact_empty: false,
            freeze_values: false,
            max_depth: Core::NORMALIZATION_MAX_DEPTH,
            symbolize_keys: false
          )
            return copy_leaf(value, freeze_values: freeze_values) unless container?(value)

            copy_with(
              cached_copier(
                compact_empty: compact_empty,
                freeze_values: freeze_values,
                max_depth: max_depth,
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

          def cached_copier(compact_empty:, freeze_values:, max_depth:, symbolize_keys:)
            # One copier per thread/options avoids per-record walker allocation.
            pool = Thread.current.thread_variable_get(POOL_KEY)
            unless pool
              pool = {}
              Thread.current.thread_variable_set(POOL_KEY, pool)
            end

            key = cache_key(
              compact_empty: compact_empty,
              freeze_values: freeze_values,
              max_depth: max_depth,
              symbolize_keys: symbolize_keys
            )
            pool[key] ||= new(
              compact_empty: compact_empty,
              freeze_values: freeze_values,
              max_depth: max_depth,
              symbolize_keys: symbolize_keys
            )
          end

          def cache_key(compact_empty:, freeze_values:, max_depth:, symbolize_keys:)
            depth_key = max_depth || -1
            flags = 0
            flags |= 1 if compact_empty
            flags |= 2 if freeze_values
            flags |= 4 if symbolize_keys
            (depth_key << 3) | flags
          end

          def copy_with(copier, value)
            return copier.call_reusable(value) unless copier.in_use?

            new(
              compact_empty: copier.compact_empty,
              freeze_values: copier.freeze_values,
              max_depth: copier.max_depth,
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

        attr_reader :compact_empty, :freeze_values, :max_depth, :symbolize_keys

        def initialize(compact_empty:, freeze_values:, max_depth:, symbolize_keys:)
          @compact_empty = compact_empty
          @freeze_values = freeze_values
          @max_depth = max_depth
          @symbolize_keys = symbolize_keys
          @in_use = false
        end

        def call(value)
          traverse(value) { |root, depth| copy_value(root, depth) }
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
          return copy_string(Serializer::MAX_DEPTH_VALUE) if depth_limited?(depth)
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
          result = {}
          value.each do |key, item|
            next if @compact_empty && self.class.omitted_empty?(item)

            copied = copy_value(item, depth + 1)
            next if @compact_empty && self.class.omitted_empty?(copied)

            result[copy_key(key)] = copied
          end
          freeze_container(result)
        end

        def copy_array(value, depth)
          result = []
          value.each do |item|
            next if @compact_empty && self.class.omitted_empty?(item)

            copied = copy_value(item, depth + 1)
            next if @compact_empty && self.class.omitted_empty?(copied)

            result << copied
          end
          freeze_container(result)
        end

        def copy_key(key)
          return key.to_sym if @symbolize_keys && key.is_a?(String)
          return copy_string(key) if key.is_a?(String)

          key
        end

        def copy_string(value)
          return value unless value.is_a?(String)

          copy = value.frozen? ? value : value.dup
          @freeze_values ? copy.freeze : copy
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
