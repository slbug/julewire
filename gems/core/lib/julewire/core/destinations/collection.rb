# frozen_string_literal: true

module Julewire
  module Core
    # @api internal
    module Destinations
      class Collection
        def initialize(destinations, on_drop:, on_failure:)
          @destinations = destinations.freeze
          @on_drop = on_drop
          @on_failure = on_failure
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
            destinations.map do |destination|
              Registry.validate!(destination)
            end.freeze
          end
        end

        def empty? = @destinations.empty?

        def emit(record)
          @destinations.each do |destination|
            emit_to_destination(destination, record)
          end
        end

        def after_fork!
          @destinations.each do |destination|
            call_destination_after_fork(destination)
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
            if attempted && deadline && remaining_timeout <= 0
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

          @destinations.reject { skip_lifecycle_destination?(it, skip_resource_identities) }
        end

        def call_destination_after_fork(destination)
          destination.after_fork! if destination.respond_to?(:after_fork!)
        rescue StandardError => e
          notify_failure(
            e,
            action: :after_fork,
            destination: destination_name(destination),
            phase: :destination_lifecycle
          )
          nil
        end

        def skip_lifecycle_destination?(destination, identities)
          return false unless identities

          identities.key?(resource_identity(destination))
        end

        def resource_identity(destination)
          return destination.resource_identity if destination.respond_to?(:resource_identity)

          destination
        end

        def emit_to_destination(destination, record)
          result = destination.emit(record)
          record_drop(:destination_rejected, destination, record) if result == false
        rescue StandardError => e
          metadata = destination_metadata(destination, record)
          notify_failure(
            e,
            **metadata,
            phase: :destination
          )
          record_drop(:destination_exception, destination, record, metadata: metadata)
          nil
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

        def record_drop(reason, destination, record, metadata: destination_metadata(destination, record))
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
