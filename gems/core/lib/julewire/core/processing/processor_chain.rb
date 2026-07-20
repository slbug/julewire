# frozen_string_literal: true

module Julewire
  module Core
    module Processing
      class ProcessorChain
        DROP = Core.sentinel(:drop)
        ErrorResult = Data.define(:draft)

        def initialize(processors:, on_error:, on_invalid:, on_invalid_draft:)
          @processors = processors
          @on_error = on_error
          @on_invalid = on_invalid
          @on_invalid_draft = on_invalid_draft
        end

        def empty? = @processors.empty?

        def call(draft)
          current = draft

          @processors.each do |processor|
            result = processor.call(current)
            current = apply_processor_result(current, processor, result)
            return DROP if current.equal?(DROP)
            return DROP unless valid_processor_draft?(processor, current)
          rescue StandardError => e
            action = handle_processor_error(processor, e, current)
            case action
            when :continue
              return DROP unless valid_processor_draft?(processor, current)
            when :drop
              return DROP
            else
              return action
            end
          end

          current
        end

        private

        def apply_processor_result(current, processor, result)
          return DROP if result == :drop
          return current if result.nil?
          return result if result.instance_of?(Records::Draft)

          @on_invalid.call(processor.processor_name, result, Records::Metadata.call(current))
          current
        end

        def handle_processor_error(processor, error, current)
          record_metadata = Records::Metadata.call(current)
          @on_error.call(error, record_metadata)

          return :continue if processor.on_error == ProcessorWrapper::FAIL_OPEN
          return :drop if processor.on_error == ProcessorWrapper::DROP

          ErrorResult.new(processor_error_record(processor, error, record_metadata))
        end

        def valid_processor_draft?(processor, draft)
          draft.validate!
        rescue StandardError => e
          @on_invalid_draft.call(processor.processor_name, e, Records::Metadata.call(draft))
          false
        end

        def processor_error_record(processor, error, record_metadata)
          Diagnostics::InternalRecords.processor_error(
            processor_name: processor.processor_name,
            error: error,
            record_metadata: record_metadata
          )
        end
      end
    end
  end
end
