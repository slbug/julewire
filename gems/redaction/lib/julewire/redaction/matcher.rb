# frozen_string_literal: true

module Julewire
  module Redaction
    class Matcher
      attr_reader :blocks

      def initialize(filters)
        @blocks, patterns = Array(filters).partition { it.is_a?(Proc) }
        normal_filters, deep_filters = patterns.partition { !deep_filter?(it) }
        @pattern = compile(normal_filters, deep: false)
        @deep_pattern = compile(deep_filters, deep: true)
        @string_scan_pattern = string_scan_pattern(normal_filters)
        @blocks.freeze
      end

      def match?(key, path: nil)
        key_string = key.to_s
        !!(pattern_match?(@pattern, key_string) || pattern_match?(@deep_pattern, path))
      end

      def empty? = @pattern.nil? && @deep_pattern.nil?

      def path_dependent? = !@deep_pattern.nil?

      def string_key_possible?(value)
        return true unless @string_scan_pattern

        @string_scan_pattern.match?(value)
      end

      private

      def compile(filters, deep:)
        patterns = filters.map do |filter|
          filter = filter.filter if filter.instance_of?(PathFilter)
          case filter
          when Regexp
            filter
          else
            escaped = Regexp.escape(filter.to_s)
            pattern = deep ? "(?:\\A|\\.)#{escaped}\\z" : "\\A#{escaped}\\z"
            Regexp.new(pattern, Regexp::IGNORECASE)
          end
        end
        Regexp.union(patterns) unless patterns.empty?
      end

      def string_scan_pattern(filters)
        return if filters.any?(Regexp)

        Regexp.new(filters.map { Regexp.escape(it.to_s) }.join("|"), Regexp::IGNORECASE)
      end

      def pattern_match?(pattern, value)
        pattern&.match?(value)
      end

      def deep_filter?(filter)
        return true if filter.instance_of?(PathFilter)
        return false if filter.instance_of?(Regexp)

        filter.to_s.include?(".")
      end
    end
  end
end
