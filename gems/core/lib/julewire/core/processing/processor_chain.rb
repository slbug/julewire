# frozen_string_literal: true

module Julewire
  module Core
    module Processing
      class ProcessorChain
        DROP = Core.sentinel(:drop)
        ErrorResult = Data.define(:draft)

        def initialize(processors:, error_backtrace_lines:, on_error:)
          @processors = processors
          @error_backtrace_lines = error_backtrace_lines
          @on_error = on_error
        end

        def empty? = @processors.empty?

        def call(draft)
          current = draft

          @processors.each do |processor|
            current = apply_processor_result(current, processor.call(current))
            break if current == :drop
          rescue StandardError => e
            action = handle_processor_error(processor, e, current)
            case action
            when :continue
              next
            when :drop
              return DROP
            else
              return action
            end
          end

          current == :drop ? DROP : current
        end

        private

        def apply_processor_result(current, result)
          return :drop if result == :drop
          return result if result.is_a?(Records::Draft)

          current
        end

        def handle_processor_error(processor, error, current)
          record_metadata = Records::Metadata.call(current)
          @on_error.call(error, record_metadata)

          return :continue if processor.on_error == ProcessorWrapper::FAIL_OPEN
          return :drop if processor.on_error == ProcessorWrapper::DROP

          ErrorResult.new(processor_error_record(processor, error, record_metadata))
        end

        def processor_error_record(processor, error, record_metadata)
          Diagnostics::InternalRecords.processor_error(
            processor_name: processor.processor_name,
            error: error,
            record_metadata: record_metadata,
            error_backtrace_lines: @error_backtrace_lines
          )
        end
      end
    end
  end
end
