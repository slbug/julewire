# frozen_string_literal: true

module Julewire
  module Core
    module Destinations
      # @api internal
      module ProcessorHandling
        private

        def processor_chain(processors)
          processors = processor_entries(processors)
          return if processors.empty?

          Processing::ProcessorChain.new(
            processors: processors,
            on_error: method(:record_processor_error),
            on_invalid: method(:record_invalid_processor_result),
            on_invalid_draft: method(:record_invalid_processor_draft)
          )
        end

        def processor_entries(value)
          case value
          when Processing::ProcessorRegistry
            value.to_a
          else
            Processing::ProcessorRegistry.new(Array(value)).to_a
          end
        end

        def process_record(record)
          return record unless @processor_chain

          processed = @processor_chain.call(Records::Draft.from_record(record))
          if processed.equal?(Processing::ProcessorChain::DROP)
            drop_processed_record
          elsif processed.instance_of?(Processing::ProcessorChain::ErrorResult)
            processed.draft.to_record
          else
            processed.to_record
          end
        end

        def drop_processed_record
          increment_counter(:processor_dropped)
          nil
        end

        def record_processor_error(error, record_metadata)
          increment_counter(:processor_error)
          notify_failure(error, phase: :destination_processor, record_metadata: record_metadata)
        end

        def record_invalid_processor_result(processor_name, result, record_metadata)
          increment_counter(:processor_invalid)
          error, metadata = Processing::InvalidResultFailure.build(
            message: "destination processor returned unsupported result",
            phase: :destination_processor_result,
            processor_name: processor_name,
            record_metadata: record_metadata,
            result: result
          )
          notify_failure(error, **metadata)
        end

        def record_invalid_processor_draft(processor_name, error, record_metadata)
          increment_counter(:processor_invalid)
          notify_failure(
            error,
            phase: :destination_processor_data,
            processor: processor_name,
            record_metadata: record_metadata
          )
        end
      end
    end
  end
end
