# frozen_string_literal: true

module Julewire
  module Rails
    class ParameterFilterPlan
      FILTERED = ::ActiveSupport::ParameterFilter::FILTERED
      RECORD_CONTAINER_KEYS = Core::Processing::RecordFieldTransform.container_keys
      RECORD_SCALAR_KEYS = Core::Processing::RecordFieldTransform.scalar_keys
      private_constant :FILTERED
      private_constant :RECORD_CONTAINER_KEYS
      private_constant :RECORD_SCALAR_KEYS

      attr_reader :filtered_field_keys

      class << self
        def build(filters)
          filters = Array(filters)
          return if filters.any? { it.is_a?(Regexp) || it.is_a?(Proc) }

          new(filters)
        end
      end

      def initialize(filters)
        simple, deep = partition_filters(filters)
        @filtered_field_keys = build_filtered_field_keys(simple, deep)
        @direct_container_filter = simple.any? && deep.empty?
        @simple_pattern = simple_filter_pattern(simple) if @direct_container_filter
      end

      def direct_container_filter? = @direct_container_filter

      def filter_value(value)
        return filter_hash(value) if value.is_a?(Hash)
        return filter_array(value) if value.is_a?(Array)

        value
      end

      private

      def partition_filters(filters)
        filters.map { it.to_s.downcase }.partition { !it.include?(".") }
      end

      def build_filtered_field_keys(simple, deep)
        (container_filter_keys(simple, deep) + scalar_filter_keys(simple)).uniq.freeze
      end

      def container_filter_keys(simple, deep)
        return RECORD_CONTAINER_KEYS if simple.any?

        deep.filter_map { it.split(".", 2).first&.to_sym }
      end

      def scalar_filter_keys(simple)
        RECORD_SCALAR_KEYS.filter do |key|
          name = key_name(key)
          simple.any? { name.include?(it) }
        end
      end

      def simple_filter_pattern(filters)
        Regexp.new(filters.map { Regexp.escape(it) }.join("|"), Regexp::IGNORECASE)
      end

      def filter_hash(value)
        result = nil
        value.each do |key, item|
          filtered = simple_key_match?(key) ? FILTERED : filter_value(item)
          next if filtered.equal?(item)

          result ||= value.dup
          result[key] = filtered
        end
        result || value
      end

      def filter_array(value)
        result = nil
        value.each_with_index do |item, index|
          filtered = filter_value(item)
          next if filtered.equal?(item)

          result ||= value.dup
          result[index] = filtered
        end
        result || value
      end

      def simple_key_match?(key)
        @simple_pattern.match?(key_name(key))
      end

      def key_name(key)
        key.is_a?(Symbol) ? key.name : key.to_s
      end
    end
  end
end
