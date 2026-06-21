# frozen_string_literal: true

require "date"
require "time"

module Julewire
  module Core
    module Serialization
      class Serializer < BoundedTraversal
        MAX_DEPTH_VALUE = BoundedTraversal::MAX_DEPTH_VALUE
        OBJECT_VALUE = "[Object]"
        NAN_VALUE = "NaN"
        INFINITY_VALUE = "Infinity"
        NEGATIVE_INFINITY_VALUE = "-Infinity"
        TRUNCATED_SUFFIX = BoundedTraversal::TRUNCATED_SUFFIX
        TRUNCATION_METADATA_KEY = BoundedTraversal::TRUNCATION_METADATA_KEY
        DEFAULT_MAX_DEPTH = BoundedTraversal::DEFAULT_MAX_DEPTH
        DEFAULT_MAX_STRING_BYTES = BoundedTraversal::DEFAULT_MAX_STRING_BYTES
        DEFAULT_MAX_ARRAY_ITEMS = BoundedTraversal::DEFAULT_MAX_ARRAY_ITEMS
        DEFAULT_MAX_HASH_KEYS = BoundedTraversal::DEFAULT_MAX_HASH_KEYS
        MAX_KEY_BYTES = DEFAULT_MAX_STRING_BYTES

        class << self
          def call(
            value,
            max_depth: DEFAULT_MAX_DEPTH,
            max_string_bytes: DEFAULT_MAX_STRING_BYTES,
            max_array_items: DEFAULT_MAX_ARRAY_ITEMS,
            max_hash_keys: DEFAULT_MAX_HASH_KEYS,
            compact_empty: false,
            max_backtrace_lines: Core::MAX_BACKTRACE_LINES
          )
            new(
              max_depth: max_depth,
              max_string_bytes: max_string_bytes,
              max_array_items: max_array_items,
              max_hash_keys: max_hash_keys,
              compact_empty: compact_empty,
              max_backtrace_lines: max_backtrace_lines
            ).serialize(value)
          end
        end

        def initialize(
          max_depth: DEFAULT_MAX_DEPTH,
          max_string_bytes: DEFAULT_MAX_STRING_BYTES,
          max_array_items: DEFAULT_MAX_ARRAY_ITEMS,
          max_hash_keys: DEFAULT_MAX_HASH_KEYS,
          compact_empty: false,
          max_backtrace_lines: Core::MAX_BACKTRACE_LINES,
          copy_strings: true
        )
          super(
            max_array_items: max_array_items,
            max_depth: max_depth,
            max_depth_value: MAX_DEPTH_VALUE,
            max_hash_keys: max_hash_keys,
            max_string_bytes: max_string_bytes,
            truncation_key: TRUNCATION_METADATA_KEY
          )
          @max_backtrace_lines = Validation.validate_integer_limit!(
            max_backtrace_lines,
            name: :max_backtrace_lines
          )
          @compact_empty = compact_empty
          @copy_strings = copy_strings
        end

        def serialize(value)
          @in_use = true
          walk(record_data(value))
        ensure
          @in_use = false
        end

        def in_use? = @in_use

        private

        def scalar_value(value, depth, _key, _path)
          return serialize_exception(value, depth) if value.is_a?(Exception)

          case value
          when nil, true, false
            clear_truncated(value)
          when Numeric
            serialize_numeric(value)
          when Symbol
            clear_truncated(value.to_s)
          when String
            serialize_string(value)
          when Time, DateTime, Date
            serialize_temporal(value)
          else
            return serialize_iso8601_temporal(value) if zone_temporal?(value)

            serialize_object(value)
          end
        rescue StandardError => e
          clear_truncated(unserializable_marker(e))
        end

        def serialize_exception(error, depth)
          shape = ExceptionShape.call(error, max_backtrace_lines: @max_backtrace_lines)
          walk_value(shape, depth + 1, nil, nil)
        end

        def hash_like?(value)
          value.is_a?(Hash) || value.is_a?(Records::PublicProjection)
        end

        def record_data(value)
          return value.serializable_data if value.is_a?(Records::Record)

          value
        end

        def serialize_numeric(value)
          return serialize_float(value) if value.is_a?(Float)
          return clear_truncated(value) if value.is_a?(Integer)
          return serialize_string(value.to_s("F")) if defined?(BigDecimal) && value.is_a?(BigDecimal)

          serialize_string(EncodingSanitizer.call(value.to_s))
        end

        def serialize_float(value)
          return clear_truncated(value) if value.finite?
          return clear_truncated(NAN_VALUE) if value.nan?

          clear_truncated(value.positive? ? INFINITY_VALUE : NEGATIVE_INFINITY_VALUE)
        end

        def serialize_temporal(value)
          return clear_truncated(value.getutc.iso8601(9)) if value.is_a?(Time)
          return clear_truncated(value.iso8601(9)) if value.is_a?(DateTime)

          clear_truncated(value.iso8601)
        end

        def serialize_iso8601_temporal(value)
          temporal = value.respond_to?(:utc) ? value.utc : value
          clear_truncated(EncodingSanitizer.call(temporal.iso8601(9)))
        end

        def zone_temporal?(value)
          value.respond_to?(:iso8601) && value.respond_to?(:time_zone)
        rescue StandardError
          false
        end

        def omitted_value?(value) = DeepCompactEmpty.omitted?(value)

        def raw_omitted_value?(value) = DeepCompactEmpty.omitted?(value)

        def key_value(key) = serialize_key(key)

        def error_value(error) = clear_truncated(unserializable_marker(error))

        def serialize_key(key)
          case key
          when String
            serialize_key_string(key)
          when Symbol
            serialize_symbol_key(key)
          when nil, true, false, Numeric
            serialize_key_string(key.to_s)
          else
            serialize_key_string(object_marker(key))
          end
        end

        def serialize_symbol_key(key)
          name = key.name
          return serialize_trusted_key_string(name) if safe_trusted_key_name?(name)

          serialize_key_string(name)
        end

        def safe_trusted_key_name?(value)
          value.ascii_only? || (value.encoding == Encoding::UTF_8 && value.valid_encoding?)
        end

        def serialize_key_string(value)
          string = EncodingSanitizer.call(value)
          return clear_truncated(copy_string(string)) if string.bytesize <= MAX_KEY_BYTES

          mark_truncated("#{string.byteslice(0, MAX_KEY_BYTES).scrub("?")}#{TRUNCATED_SUFFIX}")
        end

        def serialize_trusted_key_string(value)
          return clear_truncated(value) if value.bytesize <= MAX_KEY_BYTES

          mark_truncated("#{value.byteslice(0, MAX_KEY_BYTES).scrub("?")}#{TRUNCATED_SUFFIX}")
        end

        def serialize_object(value)
          clear_truncated(object_marker(value))
        end

        def object_marker(value)
          class_name = value.class.name
          return OBJECT_VALUE if class_name.nil? || class_name.empty?

          "[Object: #{EncodingSanitizer.call(class_name)}]"
        end

        def unserializable_marker(error)
          class_name = error.class.name
          return "[Unserializable]" if class_name.nil? || class_name.empty?

          "[Unserializable: #{EncodingSanitizer.call(class_name)}]"
        end

        def serialize_string(value)
          string = EncodingSanitizer.call(value)
          return clear_truncated(copy_string(string)) if string.bytesize <= @max_string_bytes

          mark_truncated("#{string.byteslice(0, @max_string_bytes).scrub("?")}#{TRUNCATED_SUFFIX}")
        end

        def copy_string(value)
          value.frozen? || !@copy_strings ? value : value.dup
        end

        def record_hash_truncation(fields, _raw_key, key, key_truncated, child_truncated)
          return fields unless key_truncated || child_truncated

          append_truncation_field(fields, key)
        end
      end
    end
  end
end
