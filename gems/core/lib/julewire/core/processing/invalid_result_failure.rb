# frozen_string_literal: true

module Julewire
  module Core
    module Processing
      module InvalidResultFailure
        class << self
          def build(message:, phase:, processor_name:, record_metadata:, result:)
            [
              ArgumentError.new(message),
              {
                phase: phase,
                processor: processor_name,
                record_metadata: record_metadata,
                result_class: result.class.name
              }
            ]
          end
        end
      end
    end
  end
end
