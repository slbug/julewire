# frozen_string_literal: true

module Julewire
  module Core
    module Diagnostics
      class Tail
        class Renderer
          DEFAULT_MAX_VALUE_BYTES = Serialization::TextEncoder::DEFAULT_MAX_VALUE_BYTES

          def initialize(max_value_bytes: DEFAULT_MAX_VALUE_BYTES)
            @max_value_bytes = Validation.validate_integer_limit!(
              max_value_bytes,
              name: :max_value_bytes,
              positive: true
            )
          end

          def call(entries, color: false)
            encoder = Serialization::TextEncoder.new(
              color: color,
              max_value_bytes: @max_value_bytes
            )
            entries.map { encoder.call(payload_for(it)) }.join
          end

          private

          def payload_for(entry)
            record = entry.record
            record.merge("timestamp" => record["timestamp"] || entry.at.iso8601(6))
          end
        end
      end
    end
  end
end
