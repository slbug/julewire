# frozen_string_literal: true

module Julewire
  module Core
    class CLI
      module LogFormats
        class ConsoleText
          def initialize(color: false, max_value_bytes: Serialization::TextEncoder::DEFAULT_MAX_VALUE_BYTES,
                         theme: :plain)
            @formatter = Records::ConsoleFormatter.new
            @encoder = Serialization::TextEncoder.new(
              color: color,
              max_value_bytes: max_value_bytes,
              theme: theme
            )
          end

          def call(record)
            @encoder.call(@formatter.call(record))
          end
        end
      end
    end
  end
end
