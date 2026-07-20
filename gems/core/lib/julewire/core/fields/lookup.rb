# frozen_string_literal: true

module Julewire
  module Core
    module Fields
      module Lookup
        class << self
          def value(source, key)
            return unless source.respond_to?(:[])

            source[key]
          rescue StandardError
            nil
          end

          # Decoded wire records have String keys, while in-process records use
          # Symbols. Keep this conversion at presentation boundaries instead of
          # making ordinary core lookups tolerant.
          def wire_value(source, key)
            result = value(source, key)
            result.nil? ? value(source, key.to_s) : result
          end

          def blank?(value)
            value.nil? || (value.respond_to?(:empty?) && value.empty?)
          end
        end
      end
    end
  end
end
