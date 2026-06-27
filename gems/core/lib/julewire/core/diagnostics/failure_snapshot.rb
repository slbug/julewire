# frozen_string_literal: true

module Julewire
  module Core
    module Diagnostics
      module FailureSnapshot
        class << self
          def build(error, **metadata)
            {
              at: Time.now.utc,
              action: metadata[:action],
              class: error.class.name,
              component: metadata[:component],
              destination: metadata[:destination],
              event: metadata[:event],
              integration: metadata[:integration],
              output_class: metadata[:output_class],
              phase: metadata[:phase],
              processor: metadata[:processor],
              reason: metadata[:reason],
              record: record_metadata(metadata[:record_metadata]),
              result_class: metadata[:result_class],
              status: metadata[:status]
            }.compact.freeze
          end

          private

          def record_metadata(value)
            return unless value.is_a?(Hash)

            labels = value[:labels]
            metadata = {
              event: value[:event],
              severity: value[:severity],
              source: value[:source]
            }.compact
            metadata[:labels] = Fields::FieldSet.deep_dup(labels) if labels.is_a?(Hash)
            metadata
          end
        end
      end
    end
  end
end
