# frozen_string_literal: true

require "test_helper"
require "stringio"

module Julewire
  class TestHealth < Minitest::Test
    cover Julewire::Core::Diagnostics::Health

    class FailingWriteOutput
      def write(_value)
        raise "health write failed"
      end
    end

    class FlakyWriteOutput
      def initialize
        @failed = false
      end

      def write(_value)
        return if @failed

        @failed = true
        raise "health write failed"
      end
    end

    class PlainLifecycleOutput
      def write(_value); end

      def flush; end

      def close; end
    end

    class FlakyFlushOutput
      def initialize
        @failed = false
      end

      def write(_value); end

      def flush
        return if @failed

        @failed = true
        raise "flush failed"
      end

      def close; end
    end

    class FailingFlushOutput
      def write(_value); end

      def flush
        raise "flush failed"
      end

      def close; end
    end

    def test_health_records_loss_and_marker_clear
      health = Julewire::Core::Diagnostics::Health.new(
        counter_keys: %i[lost seen]
      )

      health.increment(:seen, by: 2)
      loss = health.record_loss(reason: :output_rejected, counter: :lost, event: "request.completed")
      loss_marker = health.degradation_marker

      health.clear_degradation_if_unchanged(Object.new)

      assert_predicate health, :degraded?
      assert_same loss, health.last_loss
      assert_equal :output_rejected, loss.fetch(:reason)
      assert_equal "request.completed", loss.fetch(:event)
      assert_equal({ lost: 1, seen: 2, failures: 0 }, health.counts)

      health.clear_degradation_if_unchanged(loss_marker)

      refute_predicate health, :degraded?
      assert_same loss, health.last_loss
    end

    def test_health_records_failures_and_callback_failures
      health = Julewire::Core::Diagnostics::Health.new(
        counter_keys: %i[callback_errors custom_failures],
        callback_failure_counter: :callback_errors,
        callback_metadata: { destination: :default },
        failure_counter: :custom_failures
      )

      callback = ->(*) { raise "callback failed" }
      failure = health.record_failure(RuntimeError.new("secret"), callback: callback, phase: :emit)

      assert_same failure, health.last_failure
      assert_equal "RuntimeError", failure.fetch(:class)
      assert_equal :emit, failure.fetch(:phase)
      refute_includes failure, :message
      assert_equal({ callback_errors: 1, custom_failures: 1, failures: 1 }, health.counts)
      assert_equal "RuntimeError", health.last_callback_failure.fetch(:class)
      assert_equal :default, health.last_callback_failure.fetch(:destination)

      health.clear_failures!

      refute_predicate health, :degraded?
      assert_nil health.last_failure
      assert_nil health.last_loss
      assert_nil health.last_callback_failure
    end

    def test_health_supports_historical_status_and_no_counter_modes
      health = Julewire::Core::Diagnostics::Health.new(counter_keys: [])

      failure = health.record_failure(RuntimeError.new("secret"), counter: nil, degrade: false)
      loss = health.record_loss(reason: :filtered, counter: :unknown, degrade: false)
      snapshot = health.snapshot(status_from: :failure_or_loss, include_loss: true)

      assert_equal :degraded, snapshot.fetch(:status)
      assert_same failure, snapshot.fetch(:last_failure)
      assert_same loss, snapshot.fetch(:last_loss)
      assert_equal({ failures: 1 }, snapshot.fetch(:counts))
      assert_equal :closed, health.snapshot(status: :closed).fetch(:status)
      assert_raises(ArgumentError) { health.degraded?(status_from: :bogus) }

      health.record_callback_failure(Julewire::Core::Diagnostics::CallbackNotifier.failure("CallbackError", {}))

      assert_equal "CallbackError", health.last_callback_failure.fetch(:class)
      assert_equal({ failures: 1 }, health.counts)
    end

    def test_health_ignores_unknown_failure_counters
      health = Julewire::Core::Diagnostics::Health.new(counter_keys: [])

      failure = health.record_failure(RuntimeError.new("secret"), counter: :unknown, degrade: false)

      assert_same failure, health.last_failure
      assert_equal({ failures: 1 }, health.counts)
    end

    def test_health_historical_snapshot_includes_loss
      health = Julewire::Core::Diagnostics::Health.new(
        counter_keys: %i[failures lost seen],
        failure_counter: :failures
      )

      health.increment(:seen, by: 3)
      failure = health.record_failure(RuntimeError.new("secret"), degrade: false, component: :subscriber)
      loss = health.record_loss(reason: :policy_dropped, counter: :lost, degrade: false, source: "web")

      current_snapshot = health.snapshot(status_from: :current, include_loss: true)
      historical_snapshot = health.snapshot(status_from: :failure_or_loss, include_loss: true)

      assert_equal :ok, current_snapshot.fetch(:status)
      assert_equal :degraded, historical_snapshot.fetch(:status)
      assert_equal({ failures: 1, lost: 1, seen: 3 }, historical_snapshot.fetch(:counts))
      assert_same failure, historical_snapshot.fetch(:last_failure)
      assert_same loss, historical_snapshot.fetch(:last_loss)
      assert_equal :subscriber, failure.fetch(:component)
      refute_includes failure, :message
      assert_equal :policy_dropped, loss.fetch(:reason)
      assert_equal "web", loss.fetch(:source)
    end

    def test_health_success_and_clear_modes
      health = Julewire::Core::Diagnostics::Health.new(counter_keys: %i[failures lost])

      health.record_failure(RuntimeError.new("secret"))
      health.record_loss(reason: :policy_dropped, counter: :lost)

      health.record_success

      assert_equal :ok, health.snapshot(status_from: :current).fetch(:status)
      assert_equal :degraded, health.snapshot(status_from: :failure_or_loss).fetch(:status)

      health.clear_failures!

      assert_equal :ok, health.snapshot(status_from: :failure_or_loss, include_loss: true).fetch(:status)
      assert_nil health.last_failure
      assert_nil health.last_loss
    end

    def test_health_marker_compare_and_no_counter_modes
      health = Julewire::Core::Diagnostics::Health.new(counter_keys: [])

      loss = health.record_loss(reason: :filtered, counter: nil)
      marker = health.degradation_marker

      health.clear_degradation_if_unchanged(Object.new)

      assert_predicate health, :degraded?

      health.clear_degradation_if_unchanged(marker)

      refute_predicate health, :degraded?
      assert_same loss, health.last_loss

      failure = health.record_failure(RuntimeError.new("secret"), counter: nil, degrade: false)

      assert_same failure, health.last_failure
      assert_equal({ failures: 1 }, health.counts)
      assert_raises(ArgumentError) { health.snapshot(status_from: :bogus) }
    end

    def test_health_reports_unconfigured_output
      health = Julewire.health

      refute health.dig(:pipeline, :configured)
      assert_empty health.fetch(:pipeline).fetch(:destinations)
      assert_kind_of Integer, health.fetch(:generation)
      assert_nil health.dig(:pipeline, :last_failure)
    end

    def test_health_reports_pipeline_failures_without_error_message
      Julewire.configure do |config|
        configure_destination(config, output: FailingWriteOutput.new)
      end

      Julewire.emit("will fail")

      destination = Julewire.health.dig(:pipeline, :destinations, :default)

      assert_equal :degraded, Julewire.health.fetch(:status)
      assert_equal :degraded, destination.fetch(:status)
      assert_equal 1, destination.dig(:counts, :failures)
      refute_includes destination, :last_message
    end

    def test_destination_degraded_status_recovers_after_successful_write
      Julewire.configure do |config|
        configure_destination(config, output: FlakyWriteOutput.new)
      end

      Julewire.emit("will fail")

      assert_equal :degraded, Julewire.health.dig(:pipeline, :destinations, :default, :status)

      Julewire.emit("will recover")
      destination = Julewire.health.dig(:pipeline, :destinations, :default)

      assert_equal :ok, destination.fetch(:status)
      assert_equal 1, destination.dig(:counts, :failures)
      assert_equal "RuntimeError", destination.dig(:last_failure, :class)
    end

    def test_health_degrades_when_lifecycle_failure_has_no_loss
      Julewire.configure do |config|
        configure_destination(config, output: FailingFlushOutput.new)
      end

      refute Julewire.flush

      health = Julewire.health
      destination = health.dig(:pipeline, :destinations, :default)

      assert_equal :degraded, health.fetch(:status)
      assert_equal :degraded, destination.fetch(:status)
      assert_nil destination.fetch(:last_loss)
      assert_equal "RuntimeError", destination.dig(:last_failure, :class)
    end

    def test_destination_degraded_status_recovers_after_successful_lifecycle_call
      Julewire.configure do |config|
        configure_destination(config, output: FlakyFlushOutput.new)
      end

      refute Julewire.flush

      assert_equal :degraded, Julewire.health.dig(:pipeline, :destinations, :default, :status)

      assert Julewire.flush
      destination = Julewire.health.dig(:pipeline, :destinations, :default)

      assert_equal :ok, destination.fetch(:status)
      assert_equal 1, destination.dig(:counts, :failures)
      assert_equal "RuntimeError", destination.dig(:last_failure, :class)
    end

    def test_health_reports_integration_failures_without_error_messages
      Julewire::Core::Diagnostics::ProcessIntegrationHealth.record_failure(
        :web,
        RuntimeError.new("secret"),
        action: :emit,
        component: :event_subscriber
      )

      health = Julewire.health
      integration = health.dig(:process_integrations, :web)

      assert_equal :degraded, health.fetch(:status)
      assert_equal :degraded, integration.fetch(:status)
      assert_equal 1, integration.dig(:counts, :failures)
      assert_equal "RuntimeError", integration.dig(:last_failure, :class)
      assert_equal :integration, integration.dig(:last_failure, :phase)
      assert_equal :event_subscriber, integration.dig(:last_failure, :component)
      refute_includes integration.fetch(:last_failure), :message
    end

    def test_integration_health_status_recovers_after_success
      Julewire.configure { configure_destination(it, output: StringIO.new) }
      Julewire::Core::Diagnostics::ProcessIntegrationHealth.record_failure(
        :web,
        RuntimeError.new("secret"),
        action: :emit,
        component: :event_subscriber
      )

      Julewire::Core::Diagnostics::ProcessIntegrationHealth.record_success(:web)

      health = Julewire.health
      integration = health.dig(:process_integrations, :web)

      assert_equal :ok, health.fetch(:status)
      assert_equal :ok, integration.fetch(:status)
      assert_equal 1, integration.dig(:counts, :failures)
      assert_equal "RuntimeError", integration.dig(:last_failure, :class)
    end
  end
end
