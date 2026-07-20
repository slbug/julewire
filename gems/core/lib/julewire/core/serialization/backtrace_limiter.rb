# frozen_string_literal: true

module Julewire
  module Core
    module Serialization
      class BacktraceLimiter
        MAX_CAUSE_DEPTH = Core::NORMALIZATION_MAX_DEPTH
        private_constant :MAX_CAUSE_DEPTH

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
          limit_backtraces(value, Set.new.compare_by_identity)
          value
        end

        private

        def limit_backtraces(value, seen)
          MAX_CAUSE_DEPTH.times do
            break unless value.is_a?(Hash)
            break if seen.include?(value)

            seen.add(value)
            limit_backtrace_field!(value)
            value = value[:cause]
          end
        end

        def limit_backtrace_field!(error)
          return unless error.key?(:backtrace)

          if @max_backtrace_lines.zero?
            error.delete(:backtrace)
          else
            backtrace = error.fetch(:backtrace)
            error[:backtrace] = backtrace.first(@max_backtrace_lines) if backtrace.is_a?(Array)
          end
        end
      end
    end
  end
end
