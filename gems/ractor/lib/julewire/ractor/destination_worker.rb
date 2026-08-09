# frozen_string_literal: true

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
        close_owned_output = true
        loop do
          message = command_port.receive
          current_command = command(message)
          break if current_command == :close_worker

          if current_command == :quiesce_worker
            close_owned_output = false
            break
          end

          break if dispatch(message, current_command) == :close
        end
      ensure
        close_output if close_owned_output
      end

      private

      def dispatch(message, current_command)
        case current_command
        when :emit
          emit(
            message.fetch(:record),
            parent_degradation_marker: message.fetch(:degradation_marker)
          )
        when :flush
          reply_to(message, call_output_lifecycle(:flush))
        when :close
          reply_to(message, call_output_lifecycle(:close))
          :close
        when :health
          reply_to(message, health)
        else
          raise ArgumentError, "unknown ractor destination command: #{current_command.inspect}"
        end
      end

      def command(message)
        Core::Integration::Protocol.validate_symbol_hash(message)
        message.fetch(:command)
      end

      def emit(record, parent_degradation_marker:)
        accepted = @health.recover_if_successful { @write_step.call(record) }
        ack(accepted ? :accepted : :dropped, degradation_marker: parent_degradation_marker)
      end

      def call_output_lifecycle(method_name)
        return close_lifecycle_succeeds? if method_name == :close

        @health.recover_if_successful do
          !@output.respond_to?(method_name) || @output.public_send(method_name) != false
        end
      rescue StandardError => e
        record_failure(e, phase: :output_lifecycle, action: method_name)
        false
      end

      def close_lifecycle_succeeds?
        return true if @output.respond_to?(:closed?) && @output.closed?
        return @output.close != false if @close_output && @output.respond_to?(:close)
        return @output.flush != false if @output.respond_to?(:flush)

        true
      end

      def close_output
        return if @output.respond_to?(:closed?) && @output.closed?
        return unless @close_output && @output.respond_to?(:close)

        @output.close
      rescue StandardError
        nil
      end

      def health
        @health.snapshot
      end

      def increment(key)
        @health.increment(key)
      end

      def record_failure(error, **metadata)
        @health.record_failure(error, **metadata)
      end

      def record_loss(reason, **metadata)
        @health.record_loss(reason: reason, counter: nil, **metadata)
      end

      def record_write_step_failure(error, metadata)
        record_failure(error, **metadata)
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

      def ack(status, degradation_marker:)
        @ack_port.send({ degradation_marker: degradation_marker, event: :ack, status: status })
      end

      def reply_to(message, response)
        reply = message.fetch(:reply)
        raise TypeError, "ractor destination reply must be a Ractor::Port" unless reply.is_a?(::Ractor::Port)

        send_reply(reply, response)
      end

      def send_reply(reply, response)
        reply.send(response)
      rescue StandardError => e
        record_failure(e, phase: :reply)
      end
    end

    private_constant :DestinationWorker
  end
end
