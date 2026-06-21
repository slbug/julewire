# frozen_string_literal: true

module Julewire
  module Core
    module Records
      class PublicProjection
        include Enumerable

        INTERNAL_KEYS = Fields::Bags.hidden_output_sections
        INTERNAL_EXECUTION_KEYS = %i[
          ancestors
          ancestors_truncated
          depth
          parent
          root
        ].freeze

        class << self
          def public_execution(value)
            return value unless INTERNAL_EXECUTION_KEYS.any? { value.key?(it) }

            value.except(*INTERNAL_EXECUTION_KEYS)
          end
        end

        def initialize(record)
          Record.validate_normalized!(record)
          @record = record
        end

        def each
          return enum_for(:each) unless block_given?

          @record.each do |key, value|
            next if INTERNAL_KEYS.include?(key)

            yield key, output_value(key, value)
          end
        end

        private

        def output_value(key, value)
          return self.class.public_execution(value) if key == :execution && value.is_a?(Hash)

          value
        end
      end
    end
  end
end
