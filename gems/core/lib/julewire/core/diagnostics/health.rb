# frozen_string_literal: true

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
          @mutex = Mutex.new
          counter_keys = counter_keys.to_a
          counter_keys = counter_keys.union([:failures]) if @track_failures
          @counts = counter_keys.to_h { [it, 0] }
          @current_degradation = nil
          @last_callback_failure = nil
          @last_failure = nil
          @last_loss = nil
        end

        def increment(key, by: 1)
          @mutex.synchronize { increment_unlocked(key, by: by) }
        end

        def counts
          @mutex.synchronize { @counts.dup.freeze }
        end

        def degradation_marker
          @mutex.synchronize { @current_degradation }
        end

        def degraded?(status_from: :current)
          @mutex.synchronize { degraded_unlocked?(status_from) }
        end

        def last_callback_failure
          @mutex.synchronize { @last_callback_failure }
        end

        def last_failure
          @mutex.synchronize { @last_failure }
        end

        def last_loss
          @mutex.synchronize { @last_loss }
        end

        def clear_degradation
          @mutex.synchronize { @current_degradation = nil }
        end

        def clear_degradation_if_unchanged(marker)
          @mutex.synchronize { @current_degradation = nil if @current_degradation.equal?(marker) }
        end

        def clear_failures!
          @mutex.synchronize do
            @current_degradation = nil
            @last_callback_failure = nil
            @last_failure = nil
            @last_loss = nil
          end
          self
        end

        def record_failure(error, callback: nil, counter: @failure_counter, degrade: true, **metadata)
          failure = FailureSnapshot.build(error, **metadata)
          @mutex.synchronize do
            increment_unlocked(:failures) if @track_failures
            increment_unlocked(counter) if counter && counter != :failures && @counts.key?(counter)
            @last_failure = failure
            @current_degradation = failure if degrade
          end
          notify_failure_callback(callback, error, metadata)
          failure
        end

        def record_callback_failure(callback_failure)
          @mutex.synchronize do
            @last_callback_failure = callback_failure.to_h
            increment_unlocked(@callback_failure_counter) if @callback_failure_counter
          end
        end

        def record_loss(reason:, counter: reason, degrade: true, **metadata)
          loss = { reason: reason }.merge(metadata).compact.freeze
          @mutex.synchronize do
            increment_unlocked(counter) if counter && @counts.key?(counter)
            @last_loss = loss
            @current_degradation = loss if degrade
          end
          loss
        end

        def record_success
          @mutex.synchronize { @current_degradation = nil }
          self
        end

        def snapshot(status: nil, status_from: :current, include_loss: false, **fields)
          @mutex.synchronize do
            result = {
              counts: @counts.dup.freeze,
              last_failure: @last_failure,
              status: status || (degraded_unlocked?(status_from) ? :degraded : :ok)
            }
            result[:last_loss] = @last_loss if include_loss
            result.merge(fields).compact.freeze
          end
        end

        private

        def notify_failure_callback(callback, error, metadata)
          callback_result = CallbackNotifier.call(callback, error, @callback_metadata.merge(metadata))
          record_callback_failure(callback_result) if CallbackNotifier.failure?(callback_result)
        end

        def increment_unlocked(key, by: 1)
          @counts[key] = @counts.fetch(key) + by
        end

        def degraded_unlocked?(status_from)
          case status_from
          when :current
            !!@current_degradation
          when :failure_or_loss
            !!(@last_failure || @last_loss)
          else
            raise ArgumentError, "unknown health status source: #{status_from.inspect}"
          end
        end
      end
    end
  end
end
