# frozen_string_literal: true

module Julewire
  module Ractor
    class Fanout
      attr_reader :name

      def initialize(destinations:, name: :ractor_fanout, on_failure: nil)
        @name = Core::Destinations.normalize_name(name)
        @destinations = Array(destinations).map { normalize_destination(it) }.freeze
        raise ArgumentError, "destinations must not be empty" if @destinations.empty?

        Core::Validation.validate_callable!(on_failure, name: :on_failure, allow_nil: true)
        @on_failure = on_failure
        @health = Core::Integration::DestinationHealth.new(counter_keys: [], failure_counter: nil)
      end

      def emit(record)
        @destinations.each { emit_to_destination(it, record) }
        nil
      end

      def flush(timeout: nil)
        call_lifecycle(:flush, timeout: timeout)
      end

      def close(timeout: nil)
        call_lifecycle(:close, timeout: timeout)
      end

      def after_fork!
        @destinations.each do |destination|
          destination.after_fork! if destination.respond_to?(:after_fork!)
        rescue StandardError => e
          record_failure(e, action: :after_fork, destination: destination.name)
        end
        self
      end

      def resource_identity = self

      def health
        destinations = @destinations.to_h { [it.name, destination_health(it)] }
        @health.snapshot(
          destinations: destinations,
          status: health_status(destinations)
        )
      end

      private

      def normalize_destination(value)
        destination = value.is_a?(Hash) ? Destination.new(**value) : value
        Core::Destinations::Registry.validate!(destination)
      end

      def emit_to_destination(destination, record)
        destination.emit(record)
      rescue StandardError => e
        record_failure(e, action: :emit, destination: destination.name, record_metadata: Core::Records::Metadata.call(record))
      end

      def call_lifecycle(method_name, timeout:)
        ok = true
        @destinations.each do |destination|
          ok = false if destination.public_send(method_name, timeout: timeout) == false
        rescue StandardError => e
          record_failure(e, action: method_name, destination: destination.name)
          ok = false
        end
        ok
      end

      def destination_health(destination)
        destination.health
      rescue StandardError => e
        Core::Diagnostics::FailureSnapshot.build(e, destination: destination.name, phase: :ractor_fanout_health)
      end

      def health_status(destinations)
        return :degraded if @health.last_failure
        return :degraded if destinations.any? { |_name, health| health[:status] == :degraded || health[:phase] }

        :ok
      end

      def record_failure(error, **metadata)
        @health.record_failure(error, counter: nil, phase: :ractor_fanout, **metadata)
        @on_failure&.call(error, **metadata, phase: :ractor_fanout)
      rescue StandardError
        nil
      end
    end
  end
end
