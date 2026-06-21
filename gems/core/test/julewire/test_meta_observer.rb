# frozen_string_literal: true

require "test_helper"
require "json"
require "stringio"

module Julewire
  class TestMetaObserver < Minitest::Test
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
      end
    end

    class RaisingRuntime
      def emit_without_level(**)
        raise "emit failed"
      end
    end

    def test_meta_observer_emits_degraded_runtime_health_to_named_runtime
      output = StringIO.new
      Julewire.runtime(:meta).configure { configure_destination(it, output: output) }
      observer = Julewire.observe_self!(:default, target: :meta, start: false)

      assert observer.sample!

      record = JSON.parse(output.string)

      assert_equal "julewire.runtime_health", record.fetch("event")
      assert_equal "warn", record.fetch("severity")
      assert_equal "default", record.dig("payload", "runtime")
      assert_equal "degraded", record.dig("payload", "status")
      assert_equal "degraded", record.dig("payload", "health", "status")
      assert_equal :ok, observer.health.fetch(:status)
    end

    def test_meta_observer_skips_unchanged_health
      output = StringIO.new
      Julewire.runtime(:meta).configure { configure_destination(it, output: output) }
      observer = Julewire.observe_self!(:default, target: :meta, start: false)

      assert observer.sample!
      refute observer.sample!

      assert_equal 1, output.string.lines.length
    end

    def test_meta_observer_can_include_ok_health
      output = StringIO.new
      configure_default_output(StringIO.new)
      Julewire.runtime(:meta).configure { configure_destination(it, output: output) }
      observer = Julewire.observe_self!(:default, target: :meta, include_ok: true, start: false)

      assert observer.sample!

      assert_equal "ok", JSON.parse(output.string).dig("payload", "status")
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

      scheduler.run_last

      assert_equal 2, scheduler.scheduled.length
    end

    def test_meta_observer_attach_starts_by_default
      scheduler = FakeScheduler.new

      observer = Julewire::Core::Diagnostics::MetaObserver.attach!(:default, target: :meta, scheduler: scheduler)

      assert observer.health.fetch(:running)
      assert_equal 1, scheduler.scheduled.length

      observer.stop!
    end

    def test_meta_observer_skips_ok_health_unless_requested
      runtime = HealthRuntime.new({ status: :ok })
      target = CaptureRuntime.new
      observer = Julewire::Core::Diagnostics::MetaObserver.new(runtime: runtime, target_runtime: target)

      refute observer.sample!
      assert_empty target.emits
    end

    def test_meta_observer_records_emit_failure
      runtime = HealthRuntime.new({ status: :degraded })
      observer = Julewire::Core::Diagnostics::MetaObserver.new(runtime: runtime, target_runtime: RaisingRuntime.new)

      refute observer.sample!

      assert_equal :degraded, observer.health.fetch(:status)
      assert_equal :meta_observer, observer.health.dig(:last_failure, :phase)
    end

    def test_meta_observer_validates_options
      assert_raises_message(ArgumentError, /target_name/) do
        Julewire::Core::Diagnostics::MetaObserver.new(
          runtime: Julewire.runtime,
          target_runtime: Julewire.runtime(:meta),
          target_name: nil
        )
      end

      assert_raises_message(ArgumentError, /interval/) do
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
  end
end
