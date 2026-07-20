# frozen_string_literal: true

require "concurrent/atomic/atomic_boolean"
require "concurrent/atomic/atomic_reference"

module Julewire
  module Core
    module Diagnostics
      class MetaObserver
        DEFAULT_EVENT = "julewire.runtime_health"
        DEFAULT_INTERVAL = 30

        class << self
          def attach!(runtime_name = :default, target: :meta, start: true, **)
            observer = new(
              runtime: Julewire.runtime(runtime_name),
              target_runtime: Julewire.runtime(target),
              runtime_name: runtime_name,
              target_name: target,
              **
            )
            observer.start! if start
            observer
          end
        end

        def initialize(
          runtime:,
          target_runtime:,
          runtime_name: :default,
          target_name: :meta,
          event: DEFAULT_EVENT,
          interval: DEFAULT_INTERVAL,
          include_ok: false,
          scheduler: Scheduling::SharedScheduler
        )
          @runtime = runtime
          @target_runtime = target_runtime
          @runtime_name = Core.normalize_name(runtime_name, name: :runtime_name)
          @target_name = Core.normalize_name(target_name, name: :target_name)
          @event = event.to_s
          @interval = Validation.validate_integer_limit!(interval, name: :interval, positive: true)
          @include_ok = include_ok ? true : false
          @scheduler = scheduler
          @last_failure = Concurrent::AtomicReference.new
          @last_signature = Concurrent::AtomicReference.new
          @running = Concurrent::AtomicBoolean.new
          @schedule_mutex = Mutex.new
          @serializer_pool_key = :"julewire_core_meta_observer_serializers_#{object_id}"
        end

        def start!
          return self unless @running.make_true

          schedule_next
          self
        end

        def stop!
          token = @schedule_mutex.synchronize do
            @running.make_false
            token = @token
            @token = nil
            token
          end
          @scheduler.cancel(token) if token
          self
        end

        def sample!
          health = @runtime.health
          signature = signature_for(health)
          return false if signature.eql?(@last_signature.get_and_set(signature))
          return false unless emit_health?(health)

          emit_health(health)
          true
        rescue StandardError => e
          record_failure(e)
          false
        end

        def health
          failure = @last_failure.get
          {
            event: @event,
            include_ok: @include_ok,
            interval: @interval,
            last_failure: failure,
            observed_runtime: @runtime_name,
            running: @running.true?,
            status: failure ? :degraded : :ok,
            target_runtime: @target_name
          }.compact.freeze
        end

        private

        def schedule_next
          @schedule_mutex.synchronize do
            @token = @scheduler.schedule(@interval) { scheduled_sample } if @running.true?
          end
        end

        def scheduled_sample
          return false unless @running.true?

          sample!
          schedule_next
        rescue StandardError => e
          record_failure(e)
        end

        def emit_health?(health)
          @include_ok || !health[:status].eql?(:ok)
        end

        def emit_health(health)
          status = health.fetch(:status, :unknown)
          @target_runtime.emit_without_level(
            severity: severity_for(status),
            source: :julewire,
            event: @event,
            message: "Julewire runtime #{@runtime_name} is #{status}",
            runtime: @runtime_name,
            status: status,
            health: health
          )
        end

        def severity_for(status)
          status == :ok ? :info : :warn
        end

        def signature_for(health)
          Serialization::SerializerPool.serialize_with(cached_serializer, health) { build_serializer }
        end

        def cached_serializer
          Serialization::SerializerPool.serializer(@serializer_pool_key, nil) { build_serializer }
        end

        def build_serializer
          Serializer.new(compact_empty: true)
        end

        def record_failure(error)
          failure = FailureSnapshot.build(error, phase: :meta_observer)
          @last_failure.set(failure)
        end
      end
    end
  end
end
