# frozen_string_literal: true

module Julewire
  module Core
    module Processing
      class RecordFieldTransform
        CONTAINER_KEYS = Fields::Bags.transform_container_sections
        SCALAR_KEYS = (Records::Record::REQUIRED_KEYS - CONTAINER_KEYS).freeze
        CONTAINER_KEY_SET = CONTAINER_KEYS.to_h { [it, true] }.freeze
        SCALAR_KEY_SET = SCALAR_KEYS.to_h { [it, true] }.freeze
        private_constant :CONTAINER_KEYS
        private_constant :SCALAR_KEYS
        private_constant :CONTAINER_KEY_SET
        private_constant :SCALAR_KEY_SET

        class << self
          def container_keys = CONTAINER_KEYS

          def scalar_keys = SCALAR_KEYS

          def container_key?(key) = CONTAINER_KEY_SET.key?(key)

          def scalar_key?(key) = SCALAR_KEY_SET.key?(key)
        end

        def initialize(
          max_array_items: nil,
          max_depth: nil,
          max_hash_keys: nil,
          max_string_bytes: nil,
          preserve_top_level_keys: nil,
          track_paths: false
        )
          @bounded_options = bounded_options(
            max_array_items: max_array_items,
            max_depth: max_depth,
            max_hash_keys: max_hash_keys,
            max_string_bytes: max_string_bytes
          )
          @preserve_top_level_key_set = Array(preserve_top_level_keys).to_h { [it, true] }
          @track_paths = track_paths
        end

        def call(record, &)
          record.each_with_object({}) do |(key, value), result|
            result[key] = transform_record_field(key, value, record, &)
          end
        end

        private

        def transform_record_field(key, value, record, &)
          return transform_container(key, value, record, &) if transform_container?(key, value)
          return value unless transform_scalar?(key)

          transform_scalar(key, value, record, &)
        end

        def transform_container?(key, value)
          value.is_a?(Hash) && self.class.container_key?(key)
        end

        def transform_scalar?(key)
          self.class.scalar_key?(key) && !@preserve_top_level_key_set.key?(key)
        end

        def transform_container(top_level_key, value, record, &)
          Serialization::BoundedTransform.call(
            value,
            **@bounded_options,
            track_paths: @track_paths
          ) do |item, key:, path:, depth:, **|
            yield(
              item,
              key: key,
              path: path,
              prefixed_path: prefixed_path(path, top_level_key),
              original: record,
              depth: depth,
              top_level_key: top_level_key
            )
          end
        end

        def transform_scalar(top_level_key, value, record, &)
          path = top_level_key.to_s if @track_paths
          transformed = yield(
            value,
            key: top_level_key,
            path: path,
            prefixed_path: path,
            original: record,
            depth: 1,
            top_level_key: top_level_key
          )
          transformed = value if transformed.equal?(Serialization::BoundedTransform::CONTINUE)
          bound_value(transformed)
        end

        def bound_value(value)
          Serialization::BoundedTransform.call(
            value,
            **@bounded_options
          )
        end

        def prefixed_path(path, top_level_key)
          return unless path

          "#{top_level_key}.#{path}"
        end

        def bounded_options(max_array_items:, max_depth:, max_hash_keys:, max_string_bytes:)
          {
            max_array_items: max_array_items,
            max_depth: max_depth,
            max_hash_keys: max_hash_keys,
            max_string_bytes: max_string_bytes
          }.compact
        end
      end
    end
  end
end
