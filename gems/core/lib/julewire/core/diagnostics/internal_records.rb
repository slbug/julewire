# frozen_string_literal: true

module Julewire
  module Core
    module Diagnostics
      module InternalRecords
        class << self
          def emit_error(error, error_backtrace_lines:)
            Core::Records::Draft.build(
              {
                severity: :error,
                kind: :point,
                event: "julewire.emit_error",
                source: "julewire",
                message: "Julewire emit failed",
                payload: {
                  error: failure_details(error)
                }
              },
              context: {},
              scope: nil,
              error_backtrace_lines: error_backtrace_lines
            )
          end

          def processor_error(processor_name:, error:, record_metadata:, error_backtrace_lines:)
            Core::Records::Draft.build(
              {
                severity: :error,
                kind: :point,
                event: "julewire.processor_error",
                source: "julewire",
                message: "Julewire processor failed",
                labels: labels(record_metadata),
                payload: {
                  processor: processor_name,
                  error: failure_details(error),
                  record: record_metadata
                }
              },
              context: {},
              scope: nil,
              error_backtrace_lines: error_backtrace_lines
            )
          end

          private

          def labels(record_metadata)
            labels = record_metadata[:labels]
            labels.is_a?(Hash) ? labels : {}
          end

          def failure_details(error)
            { class: error.class.name }.compact
          end
        end
      end
    end
  end
end
