# frozen_string_literal: true

module Julewire
  module Core
    module Records
      module RawInput
        # Reads user-supplied emit hashes before draft normalization.
        SEVERITY_KEYS = [:severity, "severity"].freeze
        SEVERITY_KEY = SEVERITY_KEYS.fetch(0)
        SEVERITY_STRING_KEY = SEVERITY_KEYS.fetch(1)
        private_constant :SEVERITY_KEYS, :SEVERITY_KEY, :SEVERITY_STRING_KEY

        class << self
          def explicit_severity?(input)
            hash_input?(input) && (input.key?(SEVERITY_KEY) || input.key?(SEVERITY_STRING_KEY))
          end

          def severity_key?(key)
            SEVERITY_KEYS.include?(key)
          end

          def without_severity_keys(input)
            input.except(*SEVERITY_KEYS)
          end

          def value(input, key, default: nil)
            return default unless hash_input?(input)
            return input[key] if input.key?(key)
            return input[key.to_s] if input.key?(key.to_s)

            default
          end

          def hash_input?(input)
            input.is_a?(Hash) || LazyEmitInput.input?(input)
          end
        end
      end
    end
  end
end
