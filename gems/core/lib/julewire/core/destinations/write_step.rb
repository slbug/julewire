# frozen_string_literal: true

module Julewire
  module Core
    module Destinations
      # @api integration_spi
      class WriteStep
        def initialize(
          formatter:,
          encoder:,
          output:,
          max_record_bytes:,
          increment:,
          failure:,
          loss:,
          output_class_name:
        )
          @formatter = formatter
          @encoder = encoder
          @output = output
          @max_record_bytes = max_record_bytes
          @increment = increment
          @failure = failure
          @loss = loss
          @output_class_name = output_class_name
        end

        def call(record)
          increment(:received)
          payload = format_record(record)
          return :dropped unless payload

          increment(:formatted)
          encoded = encode_payload(payload, record)
          return :dropped unless encoded
          return :dropped unless within_limit?(encoded, record)
          return :dropped unless write(encoded, record)

          increment(:output_accepted)
          :accepted
        end

        private

        def format_record(record)
          payload = @formatter.call(record)
          raise TypeError, "formatter must return a payload object" if payload.nil?

          payload
        rescue StandardError => e
          transform_error(e, phase: :formatter, counter: :formatter_error, record: record)
        end

        def encode_payload(payload, record)
          encoded = @encoder.call(payload)
          raise TypeError, "encoder must return a String" unless encoded.is_a?(String)

          encoded
        rescue StandardError => e
          transform_error(e, phase: :encode, counter: :encode_error, record: record)
        end

        def transform_error(error, phase:, counter:, record:)
          increment(counter)
          failure(error, phase: phase, record: record)
          loss(counter, record: record)
          nil
        end

        def within_limit?(encoded, record)
          return true unless @max_record_bytes

          bytesize = encoded.bytesize
          return true if bytesize <= @max_record_bytes

          increment(:record_too_large)
          loss(:record_too_large, bytesize: bytesize, max_record_bytes: @max_record_bytes, record: record)
          false
        end

        def write(encoded, record)
          result = @output.write(encoded)
          return true unless result == false

          increment(:output_rejected)
          output_error
          loss(:output_rejected, record: record)
          false
        rescue StandardError => e
          increment(:output_exception)
          output_error
          failure(e, phase: :output, action: :write, output_class: output_class_name, record: record)
          loss(:output_exception, action: :write, output_class: output_class_name, record: record)
          false
        end

        def output_error
          increment(:output_error)
        end

        def increment(counter)
          @increment.call(counter)
        end

        def failure(error, **metadata)
          @failure.call(error, metadata)
        end

        def loss(reason, **metadata)
          @loss.call(reason, metadata)
        end

        def output_class_name
          @output_class_name.call
        end
      end
    end
  end
end
