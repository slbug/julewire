# frozen_string_literal: true

module Julewire
  module SemanticLogger
    class Destination
      attr_reader :name

      def initialize(name:, formatter:, encoder: ENCODER, transport: nil, on_drop: nil, on_failure: nil,
                     **transport_options)
        @name = Core::Destinations.normalize_name(name)
        @formatter = formatter
        @encoder = encoder
        @on_drop = validate_optional_callback(on_drop, name: :on_drop)
        @on_failure = validate_optional_callback(on_failure, name: :on_failure)
        @transport = transport || Transport.new(**transport_options)
        @health = Core::Integration::DestinationHealth.new(
          callback_failure_counter: :callback_error,
          counter_keys: %i[received formatted written failed callback_error],
          failure_counter: :failed
        )
      end

      def emit(record)
        formatted = false
        increment(:received)
        payload = @formatter.call(record)
        formatted = true
        @transport.write(encoded_payload(payload), severity: record.fetch(:severity))
        record_written
        nil
      rescue StandardError => e
        record_failure(e, formatted: formatted, record: record)
        nil
      end

      def flush(*) = call_lifecycle(:flush) { @transport.flush }

      def close(*) = call_lifecycle(:close) { @transport.close }

      def reopen(*) = call_lifecycle(:reopen) { @transport.reopen }

      def after_fork! = call_lifecycle(:after_fork) { @transport.after_fork! }

      def resource_identity = @transport

      def health
        transport = @transport.health
        @health.snapshot(
          status: status(@health.degraded?, transport),
          type: "semantic_logger_destination",
          transport: transport
        )
      end

      private

      def validate_optional_callback(callback, name:)
        return unless callback
        return callback if callback.respond_to?(:call)

        raise ArgumentError, "#{name} must respond to #call"
      end

      def encoded_payload(payload)
        return payload if payload.is_a?(String)

        @encoder.call(payload)
      end

      def increment(name)
        @health.increment(name)
      end

      def record_written
        @health.increment(:formatted)
        @health.increment(:written)
        @health.clear_degraded!
      end

      def record_failure(error, formatted: false, record: nil)
        @health.increment(:formatted) if formatted
        @health.record_failure(error, destination: name, phase: :destination, record_metadata: record_metadata(record))
        notify_failure(error, phase: :destination, record_metadata: record_metadata(record))
        record_drop(:destination_exception, record)
      end

      def record_lifecycle_failure(error, action:)
        @health.record_failure(error, destination: name, action: action, phase: :destination_lifecycle)
        notify_failure(error, action: action, phase: :destination_lifecycle)
      end

      def call_lifecycle(action)
        yield
        clear_degraded
        true
      rescue StandardError => e
        record_lifecycle_failure(e, action: action)
        false
      end

      def notify_failure(error, **metadata)
        callback_result = Core::Diagnostics::CallbackNotifier.call(
          @on_failure,
          error,
          { destination: name }.merge(metadata)
        )
        record_callback_error(callback_result) if Core::Diagnostics::CallbackNotifier.failure?(callback_result)
      end

      def record_drop(reason, record)
        callback_result = Core::Diagnostics::CallbackNotifier.call(
          @on_drop,
          reason,
          {
            destination: name,
            phase: :destination,
            reason: reason,
            record_metadata: record_metadata(record)
          }
        )
        record_callback_error(callback_result) if Core::Diagnostics::CallbackNotifier.failure?(callback_result)
      end

      def record_callback_error(callback_failure)
        @health.record_callback_failure(callback_failure)
      end

      def record_metadata(record)
        Core::Records::Metadata.call(record) if record
      end

      def status(currently_degraded, transport)
        transport_status = transport[:status]
        return :closed if transport_status == :closed
        return :degraded if currently_degraded
        return :degraded if transport_status && transport_status != :ok

        :ok
      end

      def clear_degraded
        @health.clear_degraded!
      end
    end
  end
end
