# frozen_string_literal: true

module Julewire
  module Rails
    class ParameterFilterPlan
      FILTERED = ::ActiveSupport::ParameterFilter::FILTERED
      private_constant :FILTERED

      class << self
        def build(filters)
          filters = Array(filters)
          return if filters.any? { it.is_a?(Regexp) || it.is_a?(Proc) }

          simple, deep = partition_filters(filters)
          return unless simple.any? && deep.empty?

          new(simple)
        end

        private

        def partition_filters(filters)
          filters.map { it.to_s.downcase }.partition { !it.include?(".") }
        end
      end
      private_class_method :new

      def initialize(filters)
        @simple_pattern = simple_filter_pattern(filters)
      end

      def filter_value(value)
        return filter_hash(value) if value.is_a?(Hash)
        return filter_array(value) if value.is_a?(Array)

        value
      end

      private

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

      def key_name(key) = key.to_s
    end
  end
end
