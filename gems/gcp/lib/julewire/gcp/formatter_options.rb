# frozen_string_literal: true

module Julewire
  module GCP
    module FormatterOptions
      ALLOWED_KEYS = %i[
        label_formatter
        label_options
        max_label_key_bytes
        max_label_value_bytes
        max_labels
        span_id_path
        trace_id_path
        trace_sampled_path
      ].freeze

      class << self
        def validate!(options)
          Core::Validation.validate_options!(options, ALLOWED_KEYS, name: :formatter)
        end

        def trace_headers_paths(paths)
          Array(paths).filter_map { normalize_path(it, min_length: 1) }.freeze
        end

        def trace_value_path(path)
          normalize_path(path, min_length: 2)
        end

        def label_formatter(options)
          options[:label_formatter] || LabelFormatter.new(**label_options(options))
        end

        def label_options(options)
          label_options = options.fetch(:label_options, {}).dup
          %i[max_labels max_label_key_bytes max_label_value_bytes].each do |key|
            label_options[key] = options[key] if options.key?(key)
          end
          label_options
        end

        private

        def normalize_path(path, min_length:)
          return if path.nil?

          normalized = Array(path).map { normalize_path_segment(it) }
          return if normalized.length < min_length

          normalized.freeze
        end

        def normalize_path_segment(segment)
          segment.is_a?(String) ? segment.to_sym : segment
        end
      end
    end
  end
end
