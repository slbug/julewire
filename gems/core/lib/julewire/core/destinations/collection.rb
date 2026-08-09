# frozen_string_literal: true

module Julewire
  module Core
    # @api internal
    module Destinations
      class Collection
        def initialize(destinations, on_drop:, on_failure:)
          @destinations = destinations.dup.freeze
          @on_drop = on_drop
          @on_failure = on_failure
          @prepared_destinations = [].freeze
          @fork_lifecycle_mutex = Mutex.new
        end

        class << self
          def build(configuration:, defaults:, on_drop:, on_failure:)
            new(
              validate_destinations(configuration.destinations.build(defaults: defaults)),
              on_drop: on_drop,
              on_failure: on_failure
            )
          end

          private

          def validate_destinations(destinations)
            destinations.each do |destination|
              Registry.validate!(destination)
            end
          end
        end

        def empty? = @destinations.empty?

        def emit(record)
          @destinations.each do |destination|
            emit_to_destination(destination, record)
          end
        end

        def after_fork!
          @fork_lifecycle_mutex.synchronize do
            @destinations.each do |destination|
              call_destination_after_fork(destination)
            end
            @prepared_destinations = [].freeze
          end
          self
        end

        def before_fork!(timeout: nil)
          Validation.validate_timeout!(timeout, name: :timeout)
          @fork_lifecycle_mutex.synchronize do
            return self unless @prepared_destinations.empty?

            prepare_destinations_before_fork(timeout)
          end
          self
        end

        def cancel_before_fork!
          @fork_lifecycle_mutex.synchronize do
            @prepared_destinations.reverse_each { call_destination_after_fork(it) }
            @prepared_destinations = [].freeze
          end
          self
        end

        def flush(timeout: nil)
          call_lifecycle(:flush, timeout: timeout)
        end

        def close(timeout: nil, skip_resource_identities: nil)
          call_lifecycle(:close, timeout: timeout, skip_resource_identities: skip_resource_identities)
        end

        def lifecycle_resource_identities
          @destinations.each_with_object({}.compare_by_identity) do |destination, identities|
            identities[resource_identity(destination)] = true
          end
        end

        def health
          @destinations.to_h { [destination_name(it), destination_health(it)] }
        end

        private

        def prepare_destinations_before_fork(timeout)
          deadline = Scheduling::Deadline.for(timeout)
          prepared = []
          @destinations.each do |destination|
            next unless destination.respond_to?(:before_fork!)

            remaining = Scheduling::Deadline.remaining(deadline)
            prepared << destination
            result = destination.before_fork!(timeout: remaining)
            raise Error, "destination #{destination_name(destination)} rejected before_fork" if result == false
          end
          @prepared_destinations = prepared.freeze
        rescue StandardError
          prepared.reverse_each { call_destination_after_fork(it) }
          raise
        end

        def call_lifecycle(method_name, timeout:, skip_resource_identities: nil)
          Validation.validate_timeout!(timeout, name: :timeout)
          call_lifecycle_safely(method_name, timeout, skip_resource_identities)
        end

        def call_lifecycle_safely(method_name, timeout, skip_resource_identities)
          deadline = Scheduling::Deadline.for(timeout)
          ok = true
          attempted = false

          lifecycle_destinations(skip_resource_identities).each do |destination|
            remaining_timeout = Scheduling::Deadline.remaining(deadline)
            if attempted && deadline && remaining_timeout.zero?
              ok = false
              break
            end

            attempted = true
            ok = false if destination.public_send(method_name, timeout: remaining_timeout) == false
          rescue StandardError => e
            notify_failure(e, action: method_name, destination: destination.name, phase: :destination_lifecycle)
            ok = false
          end
          ok
        rescue StandardError => e
          notify_failure(e, action: method_name, phase: :output_lifecycle)
          false
        end

        def lifecycle_destinations(skip_resource_identities)
          return @destinations unless skip_resource_identities

          @destinations.reject { skip_resource_identities.key?(resource_identity(it)) }
        end

        def call_destination_after_fork(destination)
          destination.after_fork! if destination.respond_to?(:after_fork!)
        rescue UnsafeForkError
          raise
        rescue StandardError => e
          notify_failure(
            e,
            action: :after_fork,
            destination: destination_name(destination),
            phase: :destination_lifecycle
          )
        end

        def resource_identity(destination)
          return destination.resource_identity if destination.respond_to?(:resource_identity)

          destination
        end

        def emit_to_destination(destination, record)
          result = destination.emit(record)
          record_drop(:destination_rejected, metadata: destination_metadata(destination, record)) if result == false
        rescue StandardError => e
          metadata = destination_metadata(destination, record)
          notify_failure(
            e,
            **metadata,
            phase: :destination
          )
          record_drop(:destination_exception, metadata: metadata)
        end

        def destination_name(destination)
          destination.name
        rescue StandardError
          destination.class.name
        end

        def destination_health(destination)
          destination.health
        rescue StandardError => e
          {
            status: :unknown,
            type: "destination",
            last_failure: Diagnostics::FailureSnapshot.build(
              e,
              destination: destination_name(destination),
              phase: :destination_health
            )
          }
        end

        def notify_failure(error, **metadata)
          @on_failure.call(error, **metadata)
        end

        def record_drop(reason, metadata:)
          @on_drop.call(reason, phase: :destination, **metadata)
        end

        def destination_metadata(destination, record)
          {
            destination: destination_name(destination),
            record_metadata: Records::Metadata.call(record)
          }
        end
      end
    end
  end
end
