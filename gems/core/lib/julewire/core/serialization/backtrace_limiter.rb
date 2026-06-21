# frozen_string_literal: true

module Julewire
  module Core
    module Serialization
      class BacktraceLimiter
        class << self
          def call(value, max_backtrace_lines:)
            new(max_backtrace_lines: max_backtrace_lines).call(value)
          end
        end

        def initialize(max_backtrace_lines:)
          @max_backtrace_lines = Validation.validate_integer_limit!(
            max_backtrace_lines,
            name: :max_backtrace_lines
          )
        end

        def call(value)
          @seen = {}.compare_by_identity
          limit_backtraces(value)
          value
        ensure
          @seen = nil
        end

        private

        def limit_backtraces(value)
          while value.is_a?(Hash) && !@seen.key?(value)
            @seen[value] = true
            limit_backtrace_field!(value)
            value = value[:cause]
          end
        end

        def limit_backtrace_field!(error)
          return unless error.key?(:backtrace)

          if @max_backtrace_lines.zero?
            error.delete(:backtrace)
          elsif error[:backtrace].is_a?(Array)
            error[:backtrace] = error[:backtrace].first(@max_backtrace_lines)
          end
        end
      end
    end
  end
end
