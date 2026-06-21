# frozen_string_literal: true

module Julewire
  module Core
    module Integration
      # @api integration_spi
      class DestinationHealth
        def initialize(counter_keys:, failure_counter: :failures)
          @failure_counter = failure_counter
          @state = Diagnostics::Health.new(
            counter_keys: counter_keys,
            failure_counter: failure_counter,
            track_failures: failure_counter == :failures
          )
        end

        def increment(key, by: 1)
          @state.increment(key, by: by)
        end

        def record_failure(error, counter: @failure_counter, **metadata)
          @state.record_failure(error, counter: counter, degrade: false, **metadata)
        end

        def record_loss(reason:, counter: reason, **metadata)
          @state.record_loss(reason: reason, counter: counter, degrade: false, **metadata)
        end

        def clear_degraded! = @state.clear_failures!

        def degraded? = @state.degraded?(status_from: :failure_or_loss)

        def last_loss = @state.last_loss

        def last_failure = @state.last_failure

        def snapshot(status: nil, **fields)
          @state.snapshot(status: status, status_from: :failure_or_loss, include_loss: true, **fields)
        end
      end
    end
  end
end
