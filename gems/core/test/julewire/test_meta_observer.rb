# frozen_string_literal: true

require "test_helper"
require "json"
require "stringio"

module Julewire
  class TestMetaObserver < Minitest::Test
    cover Julewire::Core::Diagnostics::MetaObserver
    cover "Julewire::Core::FacadeMethods#observe_self!"
    class FakeScheduler
      attr_reader :cancelled, :scheduled

      def initialize
        @cancelled = []
        @scheduled = []
      end

      def schedule(timeout, &block)
        @scheduled << [timeout, block]
        @scheduled.length
      end

      def cancel(token) # rubocop:disable Naming/PredicateMethod -- Scheduler protocol uses #cancel.
        @cancelled << token
        true
      end

      def run_last
        @scheduled.last.last.call
      end
    end

    class HealthRuntime
      attr_accessor :payload

      def initialize(payload)
        @payload = payload
      end

      def health = @payload
    end

    class CaptureRuntime
      attr_reader :emits

      def initialize
        @emits = []
      end

      def emit_without_level(**input)
        @emits << input
        nil
      end
    end

    class BlockingHealthRuntime
      attr_reader :entered, :release

      def initialize
        @entered = Queue.new
        @release = Queue.new
      end

      def health
        @entered << true
        @release.pop
        { status: :degraded }
      end
    end

    class RaisingRuntime
      def emit_without_level(**)
        raise "emit failed"
      end
    end

    class ActiveSignatureSerializer
      def in_use? = true

      def serialize(_payload)
        raise "pooled serializer reused"
      end
    end

    class CapturingSignatureSerializer
      attr_reader :payloads

      def initialize(active:)
        @active = active
        @payloads = []
      end

      def in_use? = @active

      def serialize(payload)
        @payloads << payload
        payload
      end
    end

    class PayloadScopedSerializer
      def initialize(payload)
        @payload = payload
      end

      def in_use? = false

      def serialize(payload)
        raise "serializer pool leaked across observers" unless payload.equal?(@payload)

        payload
      end
    end

    class ReentrantMetaObserver < Julewire::Core::Diagnostics::MetaObserver
      attr_reader :fallback_serializer

      def initialize(...)
        @active_serializer = ActiveSignatureSerializer.new
        @fallback_serializer = CapturingSignatureSerializer.new(active: false)
        super
      end

      private

      def cached_serializer = @active_serializer

      def build_serializer = @fallback_serializer
    end

    class CacheHitMetaObserver < Julewire::Core::Diagnostics::MetaObserver
      attr_reader :cached_serializer

      def initialize(...)
        @cached_serializer = CapturingSignatureSerializer.new(active: false)
        super
      end

      private

      def build_serializer
        raise "fallback serializer should not be used"
      end
    end

    class CountingBuildMetaObserver < Julewire::Core::Diagnostics::MetaObserver
      attr_reader :builds

      def initialize(...)
        @builds = 0
        super
      end

      private

      def build_serializer
        @builds += 1
        super
      end
    end

    class PoolScopedMetaObserver < Julewire::Core::Diagnostics::MetaObserver
      def initialize(expected_payload:, **)
        @expected_payload = expected_payload
        super(**)
      end

      private

      def build_serializer = PayloadScopedSerializer.new(@expected_payload)
    end

    class SchedulerProbeMetaObserver < Julewire::Core::Diagnostics::MetaObserver
      # Contract method for scheduler probes.
      def sample! = false # rubocop:disable Naming/PredicateMethod
    end

    class RescheduleFailingScheduler
      attr_reader :callback

      def schedule(*, &callback)
        raise "schedule failed" if @callback

        @callback = callback
        :scheduled
      end

      def cancel(_token) = true # rubocop:disable Naming/PredicateMethod
    end

    class BlockingScheduleScheduler
      attr_reader :cancelled, :entered, :release

      def initialize
        @cancelled = []
        @entered = Queue.new
        @release = Queue.new
      end

      def schedule(*, &)
        @entered << true
        @release.pop
        :scheduled
      end

      def cancel(token) # rubocop:disable Naming/PredicateMethod -- Scheduler protocol uses #cancel.
        @cancelled << token
        true
      end
    end

    def test_meta_observer_emits_degraded_runtime_health_to_named_runtime
      output = StringIO.new
      Julewire.runtime(:meta).configure { configure_destination(it, output: output) }
      observer = Julewire.observe_self!(:default, target: :meta, start: false)

      assert_true observer.sample!

      record = JSON.parse(output.string)

      assert_equal "julewire.runtime_health", record.fetch("event")
      assert_equal "warn", record.fetch("severity")
      assert_equal "julewire", record.fetch("source")
      assert_equal "default", record.dig("payload", "runtime")
      assert_equal "degraded", record.dig("payload", "status")
      assert_equal "degraded", record.dig("payload", "health", "status")
      assert_equal :ok, observer.health.fetch(:status)
    end

    def test_observe_self_uses_named_observed_runtime
      output = StringIO.new
      Julewire.runtime(:meta).configure { configure_destination(it, output: output) }
      observer = Julewire.observe_self!(:audit, target: :meta, start: false)

      assert_true observer.sample!

      record = JSON.parse(output.string)

      assert_equal :audit, observer.health.fetch(:observed_runtime)
      assert_equal "audit", record.dig("payload", "runtime")
    end

    def test_observe_self_defaults_to_default_observed_runtime
      observer = Julewire.observe_self!(start: false)

      assert_equal :default, observer.health.fetch(:observed_runtime)
    end

    def test_meta_observer_defaults_to_shared_scheduler_and_meta_target
      scheduled = []
      cancelled = []
      runtime = HealthRuntime.new({ status: :degraded })
      target = CaptureRuntime.new
      observer = nil

      with_overridden_singleton_method(
        Julewire::Core::Scheduling::SharedScheduler,
        :schedule,
        proc { |timeout, &block|
          scheduled << [timeout, block]
          :scheduled_token
        }
      ) do
        with_overridden_singleton_method(
          Julewire::Core::Scheduling::SharedScheduler,
          :cancel,
          proc { |token|
            cancelled << token
            true
          }
        ) do
          observer = Julewire::Core::Diagnostics::MetaObserver.new(runtime: runtime, target_runtime: target)

          assert_equal :meta, observer.health.fetch(:target_runtime)
          assert_equal 30, observer.health.fetch(:interval)
          assert_false observer.health.fetch(:include_ok)
          assert_same observer, observer.start!
          assert_equal [30], scheduled.map(&:first)
          assert_same observer, observer.stop!
        end
      end

      assert_equal [:scheduled_token], cancelled
    end

    def test_meta_observer_skips_unchanged_health
      output = StringIO.new
      Julewire.runtime(:meta).configure { configure_destination(it, output: output) }
      observer = Julewire.observe_self!(:default, target: :meta, start: false)

      assert_true observer.sample!
      assert_false observer.sample!

      assert_equal 1, output.string.lines.length
    end

    def test_meta_observer_emits_changed_health_after_initial_sample
      runtime = HealthRuntime.new({ status: :degraded, version: 1 })
      target = CaptureRuntime.new
      observer = Julewire::Core::Diagnostics::MetaObserver.new(runtime: runtime, target_runtime: target)

      assert_true observer.sample!
      runtime.payload = { status: :degraded, version: 2 }

      assert_true observer.sample!

      assert_equal([1, 2], target.emits.map { it.fetch(:health).fetch(:version) })
    end

    def test_meta_observer_uses_fallback_serializer_when_cached_serializer_is_active
      assert_meta_observer_uses_serializer(ReentrantMetaObserver, :fallback_serializer)
    end

    def test_meta_observer_uses_cached_serializer_when_it_is_not_active
      assert_meta_observer_uses_serializer(CacheHitMetaObserver, :cached_serializer)
    end

    def test_meta_observer_default_serializer_is_cached_per_observer
      runtime = HealthRuntime.new({ status: :degraded, version: 1 })
      target = CaptureRuntime.new
      observer = CountingBuildMetaObserver.new(runtime: runtime, target_runtime: target)

      assert_true observer.sample!
      runtime.payload = { status: :degraded, version: 2 }

      assert_true observer.sample!

      assert_equal 1, observer.builds
      assert_equal([1, 2], target.emits.map { it.fetch(:health).fetch(:version) })
    end

    def test_meta_observer_signature_compacts_empty_health_fields
      runtime = HealthRuntime.new({ status: :degraded, empty: {}, nested: { empty: [] } })
      target = CaptureRuntime.new
      observer = Julewire::Core::Diagnostics::MetaObserver.new(runtime: runtime, target_runtime: target)

      assert_true observer.sample!
      runtime.payload = { status: :degraded }

      assert_false observer.sample!
      assert_equal 1, target.emits.length
    end

    def test_meta_observer_serializer_pool_is_scoped_per_observer
      unscoped_pool_key = :julewire_core_meta_observer_serializers_
      previous_pool = Thread.current.thread_variable_get(unscoped_pool_key)
      Thread.current.thread_variable_set(unscoped_pool_key, nil)
      first_health = { status: :degraded, observer: :first }
      second_health = { status: :degraded, observer: :second }
      first_target = CaptureRuntime.new
      second_target = CaptureRuntime.new
      first = PoolScopedMetaObserver.new(
        expected_payload: first_health,
        runtime: HealthRuntime.new(first_health),
        target_runtime: first_target
      )
      second = PoolScopedMetaObserver.new(
        expected_payload: second_health,
        runtime: HealthRuntime.new(second_health),
        target_runtime: second_target
      )

      assert_true first.sample!
      assert_true second.sample!
      assert_equal 1, first_target.emits.length
      assert_equal 1, second_target.emits.length
    ensure
      Thread.current.thread_variable_set(unscoped_pool_key, previous_pool) if defined?(unscoped_pool_key)
    end

    def test_meta_observer_can_include_ok_health
      output = StringIO.new
      configure_default_output(StringIO.new)
      Julewire.runtime(:meta).configure { configure_destination(it, output: output) }
      observer = Julewire.observe_self!(:default, target: :meta, include_ok: true, start: false)

      assert_true observer.sample!

      record = JSON.parse(output.string)

      assert_equal "info", record.fetch("severity")
      assert_equal "julewire", record.fetch("source")
      assert_equal "ok", record.dig("payload", "status")
    end

    def test_meta_observer_emits_ok_health_with_info_severity
      target = CaptureRuntime.new
      observer = Julewire::Core::Diagnostics::MetaObserver.new(
        runtime: HealthRuntime.new({ status: :ok }),
        target_runtime: target,
        include_ok: true
      )

      assert_true observer.sample!

      assert_equal :info, target.emits.fetch(0).fetch(:severity)
    end

    def test_meta_observer_coerces_event_names
      runtime = HealthRuntime.new({ status: :ok })
      target = CaptureRuntime.new
      observer = Julewire::Core::Diagnostics::MetaObserver.new(
        runtime: runtime,
        target_runtime: target,
        event: :custom_health,
        include_ok: true
      )

      assert_true observer.sample!

      assert_equal "custom_health", target.emits.fetch(0).fetch(:event)
    end

    def test_meta_observer_emits_unknown_for_health_without_status
      runtime = HealthRuntime.new({ component: :runtime })
      target = CaptureRuntime.new
      observer = Julewire::Core::Diagnostics::MetaObserver.new(runtime: runtime, target_runtime: target)

      assert_true observer.sample!

      emit = target.emits.fetch(0)

      assert_equal :warn, emit.fetch(:severity)
      assert_equal :julewire, emit.fetch(:source)
      assert_equal :unknown, emit.fetch(:status)
      assert_equal "Julewire runtime default is unknown", emit.fetch(:message)
    end

    def test_meta_observer_start_stop_and_scheduled_sample_are_deterministic
      scheduler = FakeScheduler.new
      runtime = HealthRuntime.new({ status: :degraded, component: :runtime })
      target = CaptureRuntime.new
      observer = Julewire::Core::Diagnostics::MetaObserver.new(
        runtime: runtime,
        target_runtime: target,
        scheduler: scheduler,
        interval: 5
      )

      assert_same observer, observer.start!
      assert_same observer, observer.start!
      assert_equal [5], scheduler.scheduled.map(&:first)

      scheduler.run_last

      assert_equal 1, target.emits.length
      assert_equal 2, scheduler.scheduled.length

      assert_same observer, observer.stop!
      assert_equal [2], scheduler.cancelled
      assert_same observer, observer.stop!
      assert_equal [2], scheduler.cancelled

      scheduler.run_last

      assert_equal 2, scheduler.scheduled.length

      assert_same observer, observer.start!
      assert_equal [5, 5, 5], scheduler.scheduled.map(&:first)

      scheduler.run_last

      assert_equal 4, scheduler.scheduled.length
    end

    def test_meta_observer_concurrent_start_schedules_once
      scheduler = FakeScheduler.new
      observer = meta_observer_with_scheduler(scheduler)
      start = Queue.new
      threads = Array.new(16) do
        safe_thread do
          start.pop
          observer.start!
        end
      end

      16.times { start << true }
      safe_thread_values(threads)

      assert_equal [30], scheduler.scheduled.map(&:first)
      assert_true observer.health.fetch(:running)
    ensure
      threads&.each { cleanup_thread(it) }
      observer&.stop!
    end

    def test_meta_observer_stop_waits_for_inflight_schedule_and_cancels_its_token
      scheduler = BlockingScheduleScheduler.new
      observer = meta_observer_with_scheduler(scheduler)
      start_thread = safe_thread { observer.start! }
      safe_queue_pop(scheduler.entered)
      stop_thread = safe_thread { observer.stop! }

      refute stop_thread.join(0.05), "stop completed before the in-flight schedule returned"
      scheduler.release << true

      assert_same observer, safe_thread_value(start_thread)
      assert_same observer, safe_thread_value(stop_thread)
      assert_equal [:scheduled], scheduler.cancelled
      assert_false observer.health.fetch(:running)
    ensure
      scheduler&.release&.push(true)
      cleanup_thread(start_thread) if defined?(start_thread)
      cleanup_thread(stop_thread) if defined?(stop_thread)
    end

    def test_meta_observer_stopped_callback_does_not_sample_or_reschedule
      scheduler = FakeScheduler.new
      runtime = HealthRuntime.new({ status: :degraded, version: 1 })
      target = CaptureRuntime.new
      observer = Julewire::Core::Diagnostics::MetaObserver.new(
        runtime: runtime,
        target_runtime: target,
        scheduler: scheduler
      )

      observer.start!
      callback = scheduler.scheduled.fetch(0).last
      observer.stop!
      runtime.payload = { status: :degraded, version: 2 }

      assert_false callback.call
      assert_empty target.emits
      assert_equal 1, scheduler.scheduled.length
      assert_false observer.health.fetch(:running)
    end

    def test_meta_observer_does_not_reschedule_when_stopped_during_sample
      scheduler = FakeScheduler.new
      runtime = BlockingHealthRuntime.new
      target = CaptureRuntime.new
      observer = Julewire::Core::Diagnostics::MetaObserver.new(
        runtime: runtime,
        target_runtime: target,
        scheduler: scheduler
      )
      observer.start!
      callback_thread = safe_thread { scheduler.run_last }
      safe_queue_pop(runtime.entered)

      observer.stop!
      runtime.release << true
      safe_thread_value(callback_thread)

      assert_equal 1, scheduler.scheduled.length
      assert_equal 1, target.emits.length
      assert_false observer.health.fetch(:running)
    ensure
      runtime&.release&.push(true)
      cleanup_thread(callback_thread) if defined?(callback_thread)
    end

    def test_meta_observer_attach_starts_by_default
      scheduler = FakeScheduler.new

      observer = Julewire::Core::Diagnostics::MetaObserver.attach!(:default, target: :meta, scheduler: scheduler)

      assert_true observer.health.fetch(:running)
      assert_equal 1, scheduler.scheduled.length

      observer.stop!
    end

    def test_meta_observer_attach_defaults_to_default_runtime
      scheduler = FakeScheduler.new

      observer = Julewire::Core::Diagnostics::MetaObserver.attach!(scheduler: scheduler)

      assert_equal :default, observer.health.fetch(:observed_runtime)
      assert_equal :meta, observer.health.fetch(:target_runtime)
      observer.stop!
    end

    def test_meta_observer_attach_can_skip_start
      scheduler = FakeScheduler.new

      observer = Julewire::Core::Diagnostics::MetaObserver.attach!(start: false, scheduler: scheduler)

      assert_false observer.health.fetch(:running)
      assert_empty scheduler.scheduled
    end

    def test_meta_observer_attach_routes_named_runtimes
      scheduler = FakeScheduler.new
      observed = HealthRuntime.new({ status: :degraded })
      target = CaptureRuntime.new
      runtimes = { audit: observed, sink: target }

      observer = with_overridden_singleton_method(Julewire, :runtime, proc { |name = :default|
        runtimes.fetch(name)
      }) do
        Julewire::Core::Diagnostics::MetaObserver.attach!(
          :audit,
          target: :sink,
          include_ok: true,
          start: false,
          scheduler: scheduler
        )
      end

      assert_equal :audit, observer.health.fetch(:observed_runtime)
      assert_equal :sink, observer.health.fetch(:target_runtime)
      with_overridden_singleton_method(Julewire, :health, proc { { status: :ok } }) do
        assert_true observer.sample!
      end
      assert_equal :degraded, target.emits.last.fetch(:status)
      assert_empty scheduler.scheduled
    end

    def test_meta_observer_health_reports_complete_snapshot
      scheduler = FakeScheduler.new
      observer = Julewire::Core::Diagnostics::MetaObserver.new(
        runtime: HealthRuntime.new({ status: :ok }),
        target_runtime: CaptureRuntime.new,
        runtime_name: "observed",
        target_name: "sink",
        event: "custom.health",
        interval: 7,
        include_ok: true,
        scheduler: scheduler
      )

      stopped = observer.health

      assert_predicate stopped, :frozen?
      assert_equal(
        {
          event: "custom.health",
          include_ok: true,
          interval: 7,
          observed_runtime: :observed,
          running: false,
          status: :ok,
          target_runtime: :sink
        },
        stopped
      )
      refute_includes stopped, :last_failure

      observer.start!

      assert_true observer.health.fetch(:running)

      observer.stop!

      assert_false observer.health.fetch(:running)
    end

    def test_meta_observer_stop_without_start_does_not_cancel_nil_token
      scheduler = FakeScheduler.new
      observer = meta_observer_with_scheduler(scheduler)

      assert_same observer, observer.stop!

      assert_empty scheduler.cancelled
    end

    def test_meta_observer_scheduled_sample_records_reschedule_failure
      scheduler = RescheduleFailingScheduler.new
      observer = SchedulerProbeMetaObserver.new(
        runtime: HealthRuntime.new({ status: :degraded }),
        target_runtime: CaptureRuntime.new,
        scheduler: scheduler
      )

      observer.start!
      result = scheduler.callback.call

      failure = observer.health.fetch(:last_failure)

      assert_same failure, result
      assert_equal "RuntimeError", failure.fetch(:class)
      assert_equal :meta_observer, failure.fetch(:phase)
    ensure
      observer&.stop!
    end

    def test_meta_observer_skips_ok_health_unless_requested
      runtime = HealthRuntime.new({ status: :ok })
      target = CaptureRuntime.new
      observer = Julewire::Core::Diagnostics::MetaObserver.new(runtime: runtime, target_runtime: target)

      assert_false observer.sample!
      assert_empty target.emits
    end

    def test_meta_observer_records_emit_failure
      runtime = HealthRuntime.new({ status: :degraded })
      observer = Julewire::Core::Diagnostics::MetaObserver.new(runtime: runtime, target_runtime: RaisingRuntime.new)

      assert_false observer.sample!

      assert_equal :degraded, observer.health.fetch(:status)
      failure = observer.health.fetch(:last_failure)

      assert_equal "RuntimeError", failure.fetch(:class)
      assert_equal :meta_observer, failure.fetch(:phase)
    end

    def test_meta_observer_validates_options
      assert_raises_message(ArgumentError, /target_name/) do
        Julewire::Core::Diagnostics::MetaObserver.new(
          runtime: Julewire.runtime,
          target_runtime: Julewire.runtime(:meta),
          target_name: nil
        )
      end

      assert_raises_message(ArgumentError, "interval must be a positive Integer") do
        Julewire.observe_self!(:default, target: :meta, interval: 0, start: false)
      end

      assert_raises_message(ArgumentError, /runtime_name must be a String or Symbol/) do
        Julewire::Core::Diagnostics::MetaObserver.new(
          runtime: Julewire.runtime,
          target_runtime: Julewire.runtime(:meta),
          runtime_name: Object.new
        )
      end

      assert_raises_message(ArgumentError, /target_name must not be empty/) do
        Julewire::Core::Diagnostics::MetaObserver.new(
          runtime: Julewire.runtime,
          target_runtime: Julewire.runtime(:meta),
          target_name: ""
        )
      end
    end

    private

    def assert_meta_observer_uses_serializer(observer_class, serializer_name)
      runtime = HealthRuntime.new({ status: :degraded, component: :runtime })
      target = CaptureRuntime.new
      observer = observer_class.new(runtime: runtime, target_runtime: target)

      assert_true observer.sample!
      assert_equal [runtime.health], observer.public_send(serializer_name).payloads
      assert_equal 1, target.emits.length
    end

    def meta_observer_with_scheduler(scheduler)
      Julewire::Core::Diagnostics::MetaObserver.new(
        runtime: HealthRuntime.new({ status: :ok }),
        target_runtime: CaptureRuntime.new,
        scheduler: scheduler
      )
    end
  end
end
