# frozen_string_literal: true

module Julewire
  module GCP
    class LabelFormatter
      def initialize(max_labels: GCP::DEFAULT_MAX_LABELS,
                     max_label_key_bytes: GCP::DEFAULT_MAX_LABEL_KEY_BYTES,
                     max_label_value_bytes: GCP::DEFAULT_MAX_LABEL_VALUE_BYTES)
        @max_labels = validate_count_limit(max_labels, name: :max_labels)
        @max_label_key_bytes = validate_byte_limit(max_label_key_bytes, name: :max_label_key_bytes)
        @max_label_value_bytes = validate_byte_limit(max_label_value_bytes, name: :max_label_value_bytes)
      end

      def call(labels)
        return if labels.empty?

        labels.each_with_object({}) do |(key, value), result|
          break result if @max_labels && result.size >= @max_labels

          label_key = label_key(key)
          next unless label_key

          result[label_key] = bounded_label_string(value, @max_label_value_bytes)
        end
      end

      private

      def label_key(value)
        key = label_string(value)
        return key unless @max_label_key_bytes && key.bytesize > @max_label_key_bytes

        nil
      end

      def bounded_label_string(value, max_bytes)
        string = label_string(value)
        return string unless max_bytes && string.bytesize > max_bytes

        label_string(string.byteslice(0, max_bytes))
      end

      def label_string(value)
        Core::Serialization::EncodingSanitizer.call(value.to_s)
      end

      def validate_count_limit(value, name:)
        return if value.nil?

        Core::Validation.validate_integer_limit!(value, name: name, positive: true)
      end

      def validate_byte_limit(value, name:)
        Core::Validation.validate_byte_limit!(value, name: name)
        value
      end
    end
  end
end
