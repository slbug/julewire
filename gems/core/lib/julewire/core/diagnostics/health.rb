# frozen_string_literal: true

require "concurrent/atomic/atomic_fixnum"
require "concurrent/atomic/atomic_reference"

module Julewire
  module Core
    module Diagnostics
      class Health
        def initialize(
          counter_keys:,
          callback_failure_counter: nil,
          callback_metadata: {},
          failure_counter: nil,
          track_failures: true
        )
          @callback_failure_counter = callback_failure_counter
          @callback_metadata = callback_metadata
          @failure_counter = failure_counter
          @track_failures = track_failures
          counter_keys = counter_keys.map { it }
          counter_keys = counter_keys.union([:failures]) if @track_failures
          @counts = counter_keys.to_h { [it, Concurrent::AtomicFixnum.new] }
          @current_degradation = Concurrent::AtomicReference.new
          @last_callback_failure = Concurrent::AtomicReference.new
          @last_failure = Concurrent::AtomicReference.new
          @last_loss = Concurrent::AtomicReference.new
        end

        def increment(key, by: 1)
          @counts.fetch(key).increment(by)
        end

        def counts
          @counts.to_h { |key, counter| [key, counter.value] }.freeze
        end

        def degradation_marker
          @current_degradation.get
        end

        def degraded?(status_from: :current)
          degraded_from?(status_from)
        end

        def last_callback_failure
          @last_callback_failure.get
        end

        def last_failure
          @last_failure.get
        end

        def last_loss
          @last_loss.get
        end

        def clear_degradation_if_unchanged(marker)
          @current_degradation.compare_and_set(marker, nil)
        end

        def clear_failures!
          @current_degradation.set(nil)
          @last_callback_failure.set(nil)
          @last_failure.set(nil)
          @last_loss.set(nil)
          self
        end

        def record_failure(error, callback: nil, counter: @failure_counter, degrade: true, **metadata)
          failure = FailureSnapshot.build(error, **metadata)
          increment(:failures) if @track_failures
          increment(counter) if counter && !counter.equal?(:failures) && @counts.key?(counter)
          @last_failure.set(failure)
          @current_degradation.set(failure) if degrade
          notify_failure_callback(callback, error, metadata)
          failure
        end

        def record_callback_failure(callback_failure)
          @last_callback_failure.set(callback_failure.to_h)
          increment(@callback_failure_counter) if @callback_failure_counter
        end

        def record_loss(reason:, counter: reason, degrade: true, **metadata)
          loss = { reason: reason }.merge(metadata).compact.freeze
          increment(counter) if counter && @counts.key?(counter)
          @last_loss.set(loss)
          @current_degradation.set(loss) if degrade
          loss
        end

        def record_success
          @current_degradation.set(nil)
          self
        end

        def snapshot(status: nil, status_from: :current, include_loss: false, **fields)
          result = {
            counts: counts,
            last_failure: last_failure,
            status: status || (degraded_from?(status_from) ? :degraded : :ok)
          }
          result[:last_loss] = last_loss if include_loss
          result.merge(fields).compact.freeze
        end

        private

        def notify_failure_callback(callback, error, metadata)
          callback_result = CallbackNotifier.call(callback, error, @callback_metadata.merge(metadata))
          record_callback_failure(callback_result) if CallbackNotifier.failure?(callback_result)
        end

        def degraded_from?(status_from)
          case status_from
          when :current
            !!degradation_marker
          when :failure_or_loss
            !!(last_failure || last_loss)
          else
            raise ArgumentError, "unknown health status source: #{status_from.inspect}"
          end
        end
      end
    end
  end
end
