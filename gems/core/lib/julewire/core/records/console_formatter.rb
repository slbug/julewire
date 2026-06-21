# frozen_string_literal: true

module Julewire
  module Core
    module Records
      # @api extension
      class ConsoleFormatter
        def call(record)
          Record.validate_normalized!(record)

          {
            event: record[:event],
            labels: record[:labels],
            message: DisplayMessage.call(record),
            payload: record[:payload],
            severity: record[:severity],
            source: record[:source],
            timestamp: record[:timestamp]
          }
        end
      end
    end
  end
end
