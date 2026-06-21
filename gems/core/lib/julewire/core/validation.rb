# frozen_string_literal: true

module Julewire
  module Core
    # @api integration_spi
    module Validation
      class << self
        def validate_byte_limit!(value, name:)
          return if value.nil?

          validate_integer_limit!(value, name: name, positive: true)
        rescue ArgumentError
          raise ArgumentError, "#{name} must be nil or a positive Integer"
        end

        def validate_non_negative_integer!(value, name:)
          validate_integer_limit!(value, name: name)
        end

        def validate_integer_limit!(value, name:, positive: false)
          return value if value.is_a?(Integer) && valid_integer_limit?(value, positive: positive)

          qualifier = positive ? "positive" : "non-negative"
          raise ArgumentError, "#{name} must be a #{qualifier} Integer"
        end

        def validate_callable!(value, name:, allow_nil: false)
          return if allow_nil && value.nil?
          return if value.respond_to?(:call)

          raise ArgumentError, "#{name} must respond to #call"
        end

        def validate_options!(options, allowed_keys, name:)
          unknown_options = options.keys - allowed_keys
          return if unknown_options.empty?

          raise ArgumentError, "unknown #{name} options: #{unknown_options.join(", ")}"
        end

        def validate_symbol_choice!(value, name:, choices:)
          choice = value.to_sym if value.respond_to?(:to_sym)
          return choice if choices.include?(choice)

          raise ArgumentError, "#{name} must be one of: #{choices.join(", ")}"
        end

        def validate_timeout!(timeout, name:)
          return if timeout.nil?
          return if valid_numeric_timeout?(timeout)

          raise ArgumentError, "#{name} must be nil or a non-negative finite Numeric"
        end

        def valid_numeric_timeout?(timeout)
          timeout.is_a?(Numeric) && timeout.finite? && timeout >= 0
        rescue StandardError
          false
        end

        def valid_integer_limit?(value, positive:)
          positive ? value.positive? : value >= 0
        end

        private :valid_integer_limit?, :valid_numeric_timeout?
      end
    end
  end
end
