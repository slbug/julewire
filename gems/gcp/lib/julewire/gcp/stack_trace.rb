# frozen_string_literal: true

module Julewire
  module GCP
    module StackTrace
      class << self
        def call(error)
          return unless error.is_a?(Hash)

          lines = lines(error)
          lines.join("\n") unless lines.empty?
        end

        def remove_backtraces(value)
          case value
          when Hash
            value.each_with_object({}) do |(key, item), copy|
              next if key == :backtrace

              copy[key] = remove_backtraces(item)
            end
          when Array
            value.map { remove_backtraces(it) }
          else
            value
          end
        end

        private

        def lines(error)
          backtrace = Array(error[:backtrace])
          cause = error[:cause]
          cause_lines = cause.is_a?(Hash) ? lines(cause) : []
          return [] if backtrace.empty? && cause_lines.empty?

          summary = Core::Records::DisplayMessage.error_summary(error)
          [summary, *backtrace, *prefixed_cause_lines(cause_lines)].compact
        end

        def prefixed_cause_lines(lines)
          lines.map.with_index { |line, index| index.zero? ? "Caused by: #{line}" : line }
        end
      end
    end
  end
end
