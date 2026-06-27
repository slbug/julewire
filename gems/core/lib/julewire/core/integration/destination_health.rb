# frozen_string_literal: true

module Julewire
  module Core
    module Integration
      # @api integration_spi
      class DestinationHealth
        def initialize(counter_keys:, callback_failure_counter: nil, failure_counter: :failures)
          @failure_counter = failure_counter
          @state = Diagnostics::Health.new(
            callback_failure_counter: callback_failure_counter,
            counter_keys: counter_keys,
            track_failures: failure_counter == :failures
          )
        end

        def increment(key, by: 1)
          @state.increment(key, by: by)
        end

        def record_failure(error, counter: @failure_counter, **metadata)
          @state.record_failure(error, counter: counter, **metadata)
        end

        def record_loss(reason:, counter: reason, **metadata)
          @state.record_loss(reason: reason, counter: counter, **metadata)
        end

        def record_callback_failure(callback_failure)
          @state.record_callback_failure(callback_failure)
        end

        def degradation_marker = @state.degradation_marker

        def clear_degradation_if_unchanged(marker) = @state.clear_degradation_if_unchanged(marker)

        def recover_if_successful
          marker = degradation_marker
          result = yield
          clear_degradation_if_unchanged(marker) unless result == false
          result
        end

        def clear_failures! = @state.clear_failures!

        def degraded? = @state.degraded?

        def last_callback_failure = @state.last_callback_failure

        def last_loss = @state.last_loss

        def last_failure = @state.last_failure

        def snapshot(status: nil, **fields)
          snapshot = @state.snapshot(status: status, include_loss: true, **fields)
          callback_failure = last_callback_failure
          return snapshot unless callback_failure

          snapshot.merge(last_callback_failure: callback_failure).freeze
        end
      end
    end
  end
end
