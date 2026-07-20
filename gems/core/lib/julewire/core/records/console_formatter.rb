# frozen_string_literal: true

module Julewire
  module Core
    module Records
      # @api extension
      class ConsoleFormatter
        def call(record)
          Record.validate_normalized!(record)

          {
            event: record.fetch(:event),
            labels: record.fetch(:labels),
            message: DisplayMessage.call(record),
            payload: record.fetch(:payload),
            severity: record.fetch(:severity),
            source: record.fetch(:source),
            timestamp: record.fetch(:timestamp)
          }
        end
      end
    end
  end
end
