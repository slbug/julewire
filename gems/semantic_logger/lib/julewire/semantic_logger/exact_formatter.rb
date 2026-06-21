# frozen_string_literal: true

module Julewire
  module SemanticLogger
    class ExactFormatter
      PAYLOAD_KEY = :julewire_value

      def call(log, _logger = nil)
        value = log.payload.fetch(PAYLOAD_KEY)
        return string_value(value) if value.is_a?(String)

        ENCODER.call(value)
      end

      private

      def string_value(value)
        return value.delete_suffix("\n") if value.end_with?("\n")
        return value.dup if value.frozen?

        value
      end
    end
  end
end
