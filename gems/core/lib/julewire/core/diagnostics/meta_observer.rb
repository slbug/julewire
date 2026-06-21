# frozen_string_literal: true

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
          @mutex = Mutex.new
          @last_signature = nil
          @last_failure = nil
          @started = false
          @stopped = false
          @token = nil
          @serializer_pool_key = :"julewire_core_meta_observer_serializers_#{object_id}"
        end

        def start!
          @mutex.synchronize do
            return self if @started && !@stopped

            @started = true
            @stopped = false
            schedule_next
          end
          self
        end

        def stop!
          token = @mutex.synchronize do
            @stopped = true
            @started = false
            @token
          end
          @scheduler.cancel(token) if token
          self
        end

        def sample!
          health = @runtime.health
          signature = signature_for(health)
          changed = @mutex.synchronize do
            changed = signature != @last_signature
            @last_signature = signature
            changed
          end
          return false unless changed
          return false unless emit_health?(health)

          emit_health(health)
          true
        rescue StandardError => e
          record_failure(e)
          false
        end

        def health
          @mutex.synchronize do
            {
              event: @event,
              include_ok: @include_ok,
              interval: @interval,
              last_failure: @last_failure,
              observed_runtime: @runtime_name,
              running: @started && !@stopped,
              status: @last_failure ? :degraded : :ok,
              target_runtime: @target_name
            }.compact.freeze
          end
        end

        private

        def schedule_next
          @token = @scheduler.schedule(@interval) { scheduled_sample }
        end

        def scheduled_sample
          sample!
          @mutex.synchronize { schedule_next unless @stopped }
        rescue StandardError => e
          record_failure(e)
        end

        def emit_health?(health)
          @include_ok || health[:status] != :ok
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
          serializer = cached_serializer
          return build_serializer.serialize(health).hash if serializer.in_use?

          serializer.serialize(health).hash
        end

        def cached_serializer
          Serialization::SerializerPool.serializer(@serializer_pool_key, :signature) { build_serializer }
        end

        def build_serializer
          Serialization::Serializer.new(compact_empty: true)
        end

        def record_failure(error)
          failure = FailureSnapshot.build(error, phase: :meta_observer)
          @mutex.synchronize { @last_failure = failure }
        end
      end
    end
  end
end
