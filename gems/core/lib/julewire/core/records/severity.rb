# frozen_string_literal: true
# shareable_constant_value: literal

module Julewire
  module Core
    module Records
      module Severity
        VALUES = %i[debug info warn error fatal unknown].freeze
        STRING_VALUES = VALUES.to_h { [it.name, it] }.freeze
        RANKS = VALUES.each_with_index.to_h.freeze
        LOGGER_INTEGER_VALUES = VALUES.each_with_index.to_h.invert.freeze

        class << self
          def normalize(value)
            case value
            when Symbol
              return value if RANKS.key?(value)
            when String
              severity = STRING_VALUES[value.downcase]
              return severity unless severity.nil?
            when Integer
              severity = LOGGER_INTEGER_VALUES[value]
              return severity unless severity.nil?
            end

            raise ArgumentError, "unsupported severity: #{value.inspect}"
          end

          def rank(value)
            RANKS.fetch(normalize(value))
          end
        end
      end
    end
  end
end
