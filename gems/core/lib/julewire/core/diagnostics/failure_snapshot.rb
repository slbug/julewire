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
              record: record_metadata(metadata[:record_metadata])
            }.compact.freeze
          end

          private

          def record_metadata(value)
            return unless value.is_a?(Hash)

            {
              event: value[:event],
              labels: value[:labels].is_a?(Hash) ? Fields::FieldSet.deep_dup(value[:labels]) : nil,
              severity: value[:severity],
              source: value[:source]
            }.compact
          end
        end
      end
    end
  end
end
