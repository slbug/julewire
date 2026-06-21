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
            return value if RANKS.key?(value)

            severity = severity_symbol(value)
            return severity if RANKS.key?(severity)

            raise ArgumentError, "unsupported severity: #{value.inspect}"
          end

          def severity_symbol(value)
            case value
            when Symbol
              value.downcase
            when String
              STRING_VALUES[value.downcase]
            when Integer
              LOGGER_INTEGER_VALUES[value]
            end
          end

          def rank(value)
            rank = RANKS[value]
            return rank unless rank.nil?

            RANKS.fetch(normalize(value))
          end
        end
      end
    end
  end
end
