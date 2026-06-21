# frozen_string_literal: true

# :nocov:
module Julewire
  module Ractor
    class DestinationWorker
      COUNTER_KEYS = %i[
        encode_error
        formatter_error
        formatted
        output_accepted
        output_error
        output_exception
        output_rejected
        received
        record_too_large
      ].freeze
      private_constant :COUNTER_KEYS

      class << self
        def run(command_port:, ack_port:, formatter:, encoder:, output:, max_record_bytes:, close_output:)
          new(formatter: formatter, encoder: encoder, output: output, max_record_bytes: max_record_bytes,
              close_output: close_output).run(command_port: command_port, ack_port: ack_port)
        end
      end

      def initialize(formatter:, encoder:, output:, max_record_bytes:, close_output:)
        @formatter = formatter
        @encoder = encoder
        @output = output
        @max_record_bytes = max_record_bytes
        @close_output = close_output
        @health = Core::Integration::DestinationHealth.new(counter_keys: COUNTER_KEYS, failure_counter: nil)
        @write_step = Core::Destinations::WriteStep.new(
          formatter: @formatter,
          encoder: @encoder,
          output: @output,
          max_record_bytes: @max_record_bytes,
          increment: method(:increment),
          failure: method(:record_write_step_failure),
          loss: method(:record_write_step_loss),
          output_class_name: method(:output_class_name)
        )
      end

      def run(command_port:, ack_port:)
        @ack_port = ack_port
        loop do
          message = command_port.receive
          break if close_message?(message)

          break if dispatch(message) == :close
        end
      ensure
        close_output
        ack(:closed)
      end

      private

      def close_message?(message)
        message.is_a?(Hash) && message[:command] == :close_worker
      end

      def dispatch(message)
        return unless message.is_a?(Hash)

        case message[:command]
        when :emit
          emit(message[:record])
        when :flush
          reply_to(message, call_output_lifecycle(:flush))
        when :close
          reply_to(message, call_output_lifecycle(:close))
          :close
        when :health
          reply_to(message, health)
        end
      rescue StandardError => e
        record_failure(e, phase: :dispatch)
        reply_to(message, false)
      end

      def emit(record)
        ack(@write_step.call(record) == :accepted ? :accepted : :dropped)
      rescue StandardError => e
        record_failure(e, phase: :emit)
        ack(:dropped)
      end

      def call_output_lifecycle(method_name)
        return close_lifecycle if method_name == :close
        return true unless @output.respond_to?(method_name)

        @output.public_send(method_name) != false
      rescue StandardError => e
        record_failure(e, phase: :output_lifecycle, action: method_name)
        false
      end

      def close_lifecycle
        return true if output_closed?
        return @output.close != false if @close_output && @output.respond_to?(:close)
        return @output.flush != false if @output.respond_to?(:flush)

        true
      rescue StandardError => e
        record_failure(e, phase: :output_lifecycle, action: :close)
        false
      end

      def close_output
        return if output_closed?
        return unless @close_output && @output.respond_to?(:close)

        @output.close
      rescue StandardError => e
        record_failure(e, phase: :output_lifecycle, action: :close)
      end

      def output_closed?
        @output.respond_to?(:closed?) ? @output.closed? : false
      end

      def health
        @health.snapshot
      end

      def increment(key)
        @health.increment(key)
      end

      def record_failure(error, **metadata)
        @health.record_failure(error, counter: nil, **metadata)
      end

      def record_loss(reason, **metadata)
        @health.record_loss(reason: reason, counter: nil, **metadata)
      end

      def record_write_step_failure(error, metadata)
        record_failure(error, **recordless_metadata(metadata))
      end

      def record_write_step_loss(reason, metadata)
        return if %i[formatter_error encode_error].include?(reason)

        record_loss(reason, **recordless_metadata(metadata))
      end

      def output_class_name
        @output.class.name
      end

      def recordless_metadata(metadata)
        metadata.except(:record)
      end

      def ack(status)
        @ack_port.send({ event: :ack, status: status })
      rescue StandardError
        nil
      end

      def reply_to(message, response)
        reply = message[:reply]
        reply.send(response) if reply.is_a?(::Ractor::Port)
      rescue StandardError => e
        record_failure(e, phase: :reply)
      end
    end

    private_constant :DestinationWorker
  end
end
# :nocov:
