# frozen_string_literal: true

module Julewire
  module Core
    module Processing
      # @api extension
      class Match
        Rule = Data.define(:conditions, :handler)
        private_constant :Rule

        def initialize(&)
          @rules = []
          instance_eval(&) if block_given?
        end

        def on(conditions = nil, **keyword_conditions, &handler)
          raise ArgumentError, "match handler is required" unless handler

          conditions = normalize_conditions(conditions, keyword_conditions)
          @rules << Rule.new(conditions.freeze, handler)
          self
        end

        def call(draft)
          @rules.each do |rule|
            next unless matches_conditions?(draft, rule.conditions)

            result = rule.handler.call(draft)
            return result if result == :drop || result.is_a?(Records::Draft)
          end
          nil
        end

        private

        def normalize_conditions(conditions, keyword_conditions)
          fields = case conditions
                   when nil then {}
                   when Hash then conditions.dup
                   else raise ArgumentError, "match conditions must be a Hash"
                   end
          fields.merge!(keyword_conditions)
          raise ArgumentError, "match conditions are required" if fields.empty?

          fields
        end

        def matches_conditions?(draft, conditions)
          conditions.all? { |key, pattern| matches_value?(pattern, draft[key]) }
        end

        def matches_value?(pattern, value)
          case pattern
          when Hash then matches_hash?(pattern, value)
          when Proc then pattern.call(value)
          when Regexp then value.is_a?(String) && pattern.match?(value)
          when Range then pattern.cover?(value)
          when Module then value.is_a?(pattern)
          else pattern == value
          end
        end

        def matches_hash?(pattern, value)
          return false unless value.is_a?(Hash)

          pattern.all? do |key, nested_pattern|
            nested_value = Fields::FieldSet.value_for(value, key, default: Core::UNSET)
            !nested_value.equal?(Core::UNSET) && matches_value?(nested_pattern, nested_value)
          end
        end
      end
    end
  end
end
