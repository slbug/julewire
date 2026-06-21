# frozen_string_literal: true

module Julewire
  module Core
    module Serialization
      # @api integration_spi
      class BoundedTransform < BoundedTraversal
        CONTINUE = Core.sentinel(:continue)

        class << self
          def call(value, **, &)
            new(**, &).call(value)
          end
        end

        def initialize(
          max_depth: DEFAULT_MAX_DEPTH,
          max_string_bytes: DEFAULT_MAX_STRING_BYTES,
          max_array_items: DEFAULT_MAX_ARRAY_ITEMS,
          max_hash_keys: DEFAULT_MAX_HASH_KEYS,
          max_depth_value: MAX_DEPTH_VALUE,
          truncation_key: TRUNCATION_METADATA_KEY.to_sym,
          track_paths: nil,
          &block
        )
          super(
            max_array_items: max_array_items,
            max_depth: max_depth,
            max_depth_value: max_depth_value,
            max_hash_keys: max_hash_keys,
            max_string_bytes: max_string_bytes,
            truncation_key: truncation_key
          )
          @transform = block
          @prepare_values = !@transform.nil?
          @track_paths = @prepare_values && !track_paths.equal?(false)
        end

        def call(value)
          @root = value
          walk(value)
        ensure
          @root = nil
        end

        private

        def prepare_value(value, depth, key, path)
          transformed = @transform.call(value, key: key, path: path, original: @root, depth: depth)
          transformed.equal?(CONTINUE) ? value : transformed
        end
      end
    end
  end
end
