# frozen_string_literal: true

module Julewire
  module Core
    module Records
      module Metadata
        class << self
          def call(record)
            return {} unless record.respond_to?(:key?) && record.respond_to?(:[])

            {
              event: record[:event],
              labels: record[:labels].is_a?(Hash) ? Fields::FieldSet.deep_dup(record[:labels]) : {},
              logger: record[:logger],
              severity: record[:severity],
              source: record[:source]
            }.compact
          end
        end
      end
    end
  end
end
