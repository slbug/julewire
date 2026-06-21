# frozen_string_literal: true

module Julewire
  module Core
    module Records
      module LazyEmitInput
        # Merges deferred emit block output with eager severity/input fields.
        class SeverityInput
          include Enumerable

          def initialize(severity, input)
            @severity = severity
            @input = input
          end

          def key?(key)
            severity_key?(key) || input_hash.key?(key) || input_hash.key?(key.to_s)
          end

          def [](key)
            return @severity if severity_key?(key)

            RawInput.value(input_hash, key)
          end

          def each
            return enum_for(:each) unless block_given?

            input_hash.each do |key, value|
              yield key, value unless severity_key?(key)
            end
            yield :severity, @severity
          end

          def to_h
            each_with_object({}) do |(key, value), hash|
              hash[key] = value
            end
          end

          private

          def input_hash
            @input_hash ||= @input.is_a?(Hash) ? @input : { message: @input.to_s }
          end

          def severity_key?(key)
            RawInput.severity_key?(key)
          end
        end
        private_constant :SeverityInput

        class << self
          def call(input)
            lazy_value = yield
            return input if lazy_value.nil?
            return lazy_value if empty_input?(input)

            eager = input_hash(input)
            lazy = input_hash(lazy_value)
            lazy = without_severity(lazy) if explicit_severity?(eager)
            Fields::FieldSet.merge(eager, lazy)
          end

          def with_severity(severity, input)
            SeverityInput.new(severity, input)
          end

          def input?(value)
            value.is_a?(SeverityInput)
          end

          private

          def empty_input?(input)
            input.nil? || (input.is_a?(Hash) && input.empty?)
          end

          def input_hash(value)
            return value if value.is_a?(Hash)
            return value.to_h if input?(value)

            { message: value.to_s }
          end

          def explicit_severity?(input)
            RawInput.explicit_severity?(input)
          end

          def without_severity(input)
            return input unless input.is_a?(Hash)

            RawInput.without_severity_keys(input)
          end
        end
      end
    end
  end
end
