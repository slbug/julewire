# frozen_string_literal: true

require "json"

module Julewire
  module Core
    module Serialization
      # @api extension
      class JsonEncoder
        def initialize(
          max_depth: Serializer::DEFAULT_MAX_DEPTH,
          max_string_bytes: Serializer::DEFAULT_MAX_STRING_BYTES,
          max_array_items: Serializer::DEFAULT_MAX_ARRAY_ITEMS,
          max_hash_keys: Serializer::DEFAULT_MAX_HASH_KEYS,
          compact_empty: true,
          max_backtrace_lines: Core::MAX_BACKTRACE_LINES,
          append_newline: true
        )
          @max_depth = max_depth
          @max_string_bytes = max_string_bytes
          @max_array_items = max_array_items
          @max_hash_keys = max_hash_keys
          @compact_empty = compact_empty
          @max_backtrace_lines = max_backtrace_lines
          @line_suffix = append_newline ? "\n" : ""
          @serializer_key = [
            @max_depth,
            @max_string_bytes,
            @max_array_items,
            @max_hash_keys,
            @compact_empty,
            @max_backtrace_lines
          ].freeze
        end

        def call(payload)
          JSON.generate(serialized_payload(payload), allow_nan: false).tap do |json|
            json << @line_suffix
          end
        end

        private

        def serialized_payload(payload)
          serializer = cached_serializer
          return build_serializer.serialize(payload) if serializer.in_use?

          serializer.serialize(payload)
        end

        def cached_serializer
          SerializerPool.serializer(:julewire_core_json_encoder_serializers, @serializer_key) { build_serializer }
        end

        def build_serializer
          Serializer.new(
            max_depth: @max_depth,
            max_string_bytes: @max_string_bytes,
            max_array_items: @max_array_items,
            max_hash_keys: @max_hash_keys,
            compact_empty: @compact_empty,
            max_backtrace_lines: @max_backtrace_lines,
            copy_strings: false
          )
        end
      end
    end
  end
end
