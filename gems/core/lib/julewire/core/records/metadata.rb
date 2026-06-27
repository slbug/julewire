# frozen_string_literal: true

module Julewire
  module Core
    module Records
      module Metadata
        class << self
          def call(record)
            labels = record[:labels]
            {
              event: record[:event],
              labels: labels.is_a?(Hash) ? Fields::FieldSet.deep_dup(labels) : {},
              logger: record[:logger],
              severity: record[:severity],
              source: record[:source]
            }.compact
          rescue StandardError
            {}
          end
        end
      end
    end
  end
end
