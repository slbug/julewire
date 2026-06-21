# frozen_string_literal: true

module Julewire
  module Core
    module Destinations
      module Sink
        class << self
          def wrap(output, close_output: false)
            reject_output_array!(output)
            return output if wrapped?(output)

            validate_writeable!(output)
            SynchronizedOutput.new(output, close_output: close_output)
          end

          def validate_writeable!(output)
            return if output.respond_to?(:write)

            raise ArgumentError, "output must respond to #write"
          end

          def reject_output_array!(output)
            return unless output.is_a?(Array)

            raise ArgumentError, "output arrays are transport adapter behavior; use destinations or an adapter output"
          end

          private

          def wrapped?(output) = output.is_a?(SynchronizedOutput)
        end
      end
    end
  end
end
