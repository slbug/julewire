# frozen_string_literal: true

module Julewire
  module Core
    module Diagnostics
      module InternalRecords
        class << self
          def emit_error(error)
            Records::Draft.build(
              {
                severity: :error,
                event: "julewire.emit_error",
                source: "julewire",
                message: "Julewire emit failed",
                payload: {
                  error: failure_details(error)
                }
              },
              context: nil,
              scope: nil
            )
          end

          def processor_error(processor_name:, error:, record_metadata:)
            Records::Draft.build(
              {
                severity: :error,
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
              context: nil,
              scope: nil
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
