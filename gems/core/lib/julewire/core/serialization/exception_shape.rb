# frozen_string_literal: true

module Julewire
  module Core
    module Serialization
      class ExceptionShape
        include ValueTraversal

        DEFAULT_MAX_CAUSE_DEPTH = 5

        class << self
          def call(error, max_backtrace_lines: Core::MAX_BACKTRACE_LINES, max_cause_depth: DEFAULT_MAX_CAUSE_DEPTH)
            new(
              max_backtrace_lines: max_backtrace_lines,
              max_cause_depth: max_cause_depth
            ).call(error)
          end
        end

        def initialize(max_backtrace_lines:, max_cause_depth:)
          @backtrace_limiter = BacktraceLimiter.new(max_backtrace_lines: max_backtrace_lines)
          @include_backtraces = max_backtrace_lines.positive?
          @max_cause_depth = Validation.validate_integer_limit!(max_cause_depth, name: :max_cause_depth)
        end

        def call(error)
          traverse(error) { |root, depth| shape_exception(root, depth) }
        end

        private

        def shape_exception(error, depth)
          return error unless error.is_a?(Exception)

          with_traversal_container(error, Core::CIRCULAR_REFERENCE) do
            exception_hash(error, depth)
          end
        end

        def exception_hash(error, depth)
          {
            class: class_name(error),
            message: error_message(error)
          }.tap do |result|
            if @include_backtraces
              lines = backtrace(error)
              result[:backtrace] = lines if lines
            end

            cause = exception_cause(error)
            next unless cause

            if depth >= @max_cause_depth
              result[:cause_truncated] = true
            else
              result[:cause] = shape_exception(cause, depth + 1)
            end
          end
        end

        def class_name(error)
          error.class.name || error.class.to_s
        rescue StandardError
          "Exception"
        end

        def error_message(error)
          message = error.message
          message.is_a?(String) ? message.dup : message.to_s
        rescue StandardError
          "[Unavailable]"
        end

        def backtrace(error)
          @backtrace_limiter.call(backtrace: Core::Fields::FieldSet.deep_dup(error.backtrace))[:backtrace]
        rescue StandardError
          nil
        end

        def exception_cause(error)
          error.cause
        rescue StandardError
          nil
        end
      end
    end
  end
end
