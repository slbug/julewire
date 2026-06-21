# frozen_string_literal: true

module Julewire
  module Core
    module Processing
      class ProcessorWrapper
        FAIL_CLOSED = :fail_closed
        FAIL_OPEN = :fail_open
        DROP = :drop
        POLICIES = [FAIL_CLOSED, FAIL_OPEN, DROP].freeze

        attr_reader :on_error

        class << self
          def normalize_policy(value)
            Validation.validate_symbol_choice!(value, name: "processor on_error", choices: POLICIES)
          end
        end

        def initialize(processor, on_error: FAIL_CLOSED)
          validate_processor!(processor)
          @processor = processor
          @on_error = self.class.normalize_policy(on_error)
        end

        def call(...)
          @processor.call(...)
        end

        def processor_name
          @processor.class.name
        end

        private

        def validate_processor!(processor)
          return if processor.respond_to?(:call)

          raise ArgumentError, "processor must respond to call"
        end
      end
    end
  end
end
