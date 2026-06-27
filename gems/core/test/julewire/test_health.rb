# frozen_string_literal: true

require "test_helper"
require "stringio"

module Julewire
  class TestHealth < Minitest::Test
    cover Julewire::Core::Diagnostics::Health
    cover Julewire::Core::Diagnostics::IntegrationHealthStore
    cover "Julewire::Core::Diagnostics::IntegrationHealthStore#reset!"
    cover Julewire::Core::Diagnostics::ProcessIntegrationHealth
    cover "Julewire::Core::Diagnostics::ProcessIntegrationHealth.reset!"
    cover "Julewire::Core::FacadeMethods#health"
    cover "Julewire::Core::Runtime#build_runtime_health"
    cover "Julewire::Core::Runtime#configure"
    cover "Julewire::Core::Runtime#degraded_health?"
    cover "Julewire::Core::Runtime#health"
    cover "Julewire::Core::Runtime#integrations_degraded?"
    cover "Julewire::Core::Runtime#initialize"
    cover "Julewire::Core::Runtime#pipeline_degraded?"
    cover "Julewire::Core::Runtime#record_integration_failure"
    cover "Julewire::Core::Runtime#runtime_counts_snapshot"
    cover "Julewire::Core::Runtime#runtime_degraded?"
    cover "Julewire::Core::Runtime#runtime_status"
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

      assert_true health.degraded?
      assert_same loss, health.last_loss
      assert_equal :output_rejected, loss.fetch(:reason)
      assert_equal "request.completed", loss.fetch(:event)
      assert_equal({ lost: 1, seen: 2, failures: 0 }, health.counts)
      assert_true health.degraded?
      assert_true health.degraded?(status_from: :failure_or_loss)

      health.clear_degradation_if_unchanged(loss_marker)

      assert_false health.degraded?
      assert_false health.degraded?
      assert_true health.degraded?(status_from: :failure_or_loss)
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

    def test_health_successful_failure_callback_receives_error_and_merged_metadata
      health = Julewire::Core::Diagnostics::Health.new(
        counter_keys: [:callback_errors],
        callback_failure_counter: :callback_errors,
        callback_metadata: { destination: :default, source: :base }
      )
      error = RuntimeError.new("secret")
      callback_arguments = []

      failure = health.record_failure(
        error,
        callback: ->(callback_error, metadata) { callback_arguments << [callback_error, metadata] },
        destination: :override,
        phase: :emit
      )

      callback_error, metadata = callback_arguments.fetch(0)

      assert_same error, callback_error
      assert_same failure, health.last_failure
      assert_equal({ destination: :override, phase: :emit, source: :base }, metadata)
      assert_nil health.last_callback_failure
      assert_equal({ callback_errors: 0, failures: 1 }, health.counts)
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
      error = assert_raises(ArgumentError) { health.degraded?(status_from: :bogus) }

      assert_equal "unknown health status source: :bogus", error.message

      health.record_callback_failure(Julewire::Core::Diagnostics::CallbackNotifier.failure("CallbackError", {}))

      assert_equal "CallbackError", health.last_callback_failure.fetch(:class)
      assert_equal({ failures: 1 }, health.counts)
    end

    def test_health_historical_status_tracks_failure_without_loss
      health = Julewire::Core::Diagnostics::Health.new(counter_keys: [])

      failure = health.record_failure(RuntimeError.new("secret"), degrade: false)

      refute_predicate health, :degraded?
      assert_false health.degraded?(status_from: :current)
      assert_true health.degraded?(status_from: :failure_or_loss)
      assert_same failure, health.snapshot(status_from: :failure_or_loss).fetch(:last_failure)
    end

    def test_health_requires_counter_keys_iterable
      assert_raises(NoMethodError) do
        Julewire::Core::Diagnostics::Health.new(counter_keys: nil)
      end
    end

    def test_health_materializes_single_pass_counter_key_enumerables
      keys = Enumerator.new { it << :accepted }

      health = Julewire::Core::Diagnostics::Health.new(counter_keys: keys)

      assert_equal({ accepted: 0, failures: 0 }, health.counts)
    end

    def test_health_can_disable_automatic_failure_counter
      health = Julewire::Core::Diagnostics::Health.new(counter_keys: [], track_failures: false)

      failure = health.record_failure(RuntimeError.new("secret"), degrade: false)

      assert_same failure, health.last_failure
      assert_empty health.counts
    end

    def test_health_initial_readers_are_warning_clean
      health = Julewire::Core::Diagnostics::Health.new(counter_keys: [])
      verbose = $VERBOSE
      $VERBOSE = true

      _stdout, stderr = capture_io do
        assert_nil health.degradation_marker
        assert_nil health.last_callback_failure
        assert_nil health.last_failure
        assert_nil health.last_loss
      end

      assert_empty stderr
    ensure
      $VERBOSE = verbose
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

    def test_health_snapshot_omits_loss_by_default
      health = Julewire::Core::Diagnostics::Health.new(counter_keys: [:lost])

      health.record_loss(reason: :policy_dropped, counter: :lost)

      snapshot = health.snapshot

      refute_includes snapshot, :last_loss
      assert_same health.last_loss, health.snapshot(include_loss: true).fetch(:last_loss)
    end

    def test_health_snapshot_returns_compact_immutable_counts
      health = Julewire::Core::Diagnostics::Health.new(counter_keys: [:seen])
      health.increment(:seen, by: 2)

      snapshot = health.snapshot(component: :runtime, omitted: nil)

      assert_predicate snapshot, :frozen?
      assert_predicate snapshot.fetch(:counts), :frozen?
      assert_equal({ seen: 2, failures: 0 }, snapshot.fetch(:counts))
      assert_equal :runtime, snapshot.fetch(:component)
      refute_includes snapshot, :omitted

      health.increment(:seen)

      assert_equal 3, health.counts.fetch(:seen)
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

    def test_health_record_loss_uses_default_counter_freezes_loss_and_honors_nil_counter
      health = Julewire::Core::Diagnostics::Health.new(counter_keys: [:filtered, nil])

      loss = health.record_loss(reason: :filtered)
      ignored = health.record_loss(reason: :ignored, counter: nil)

      assert_predicate loss, :frozen?
      assert_predicate ignored, :frozen?
      assert_equal({ filtered: 1, nil => 0, failures: 0 }, health.counts)
    end

    def test_health_record_failure_honors_nil_counter_even_when_nil_counter_key_exists
      health = Julewire::Core::Diagnostics::Health.new(counter_keys: [nil])

      failure = health.record_failure(RuntimeError.new("secret"), counter: nil, degrade: false)

      assert_same failure, health.last_failure
      assert_equal({ nil => 0, failures: 1 }, health.counts)
    end

    def test_health_records_failure_loss_and_callback_failure
      health = Julewire::Core::Diagnostics::Health.new(
        counter_keys: %i[callback_errors dropped write_errors],
        callback_failure_counter: :callback_errors,
        failure_counter: :write_errors
      )
      callback_failure = Julewire::Core::Diagnostics::CallbackNotifier.failure("CallbackError", phase: :drop)

      failure = health.record_failure(RuntimeError.new("write failed"), phase: :write)
      health.record_loss(reason: :dropped)
      health.record_callback_failure(callback_failure)

      assert_equal({ callback_errors: 1, dropped: 1, write_errors: 1, failures: 1 }, health.counts)
      assert_same failure, health.last_failure
      assert_equal :write, health.last_failure.fetch(:phase)
      assert_equal callback_failure.to_h, health.last_callback_failure
    end

    def test_health_increment_updates_the_counter
      health = Julewire::Core::Diagnostics::Health.new(counter_keys: [:seen])

      health.increment(:seen, by: 2)

      assert_equal 2, health.counts.fetch(:seen)
    end

    def test_health_counts_every_concurrent_increment
      health = Julewire::Core::Diagnostics::Health.new(counter_keys: [:seen])
      start = Queue.new
      threads = Array.new(16) do
        safe_thread do
          start.pop
          100.times { health.increment(:seen) }
        end
      end

      16.times { start << true }
      safe_thread_values(threads)

      assert_equal({ seen: 1_600, failures: 0 }, health.counts)
    ensure
      threads&.each { cleanup_thread(it) }
    end

    def test_health_clear_and_success_restore_ok_status
      health = Julewire::Core::Diagnostics::Health.new(counter_keys: [])

      health.record_failure(RuntimeError.new("boom"))

      assert_same health, health.record_success
      assert_same health, health.clear_failures!

      assert_equal :ok, health.snapshot(status_from: :failure_or_loss).fetch(:status)
      assert_nil health.last_failure
    end

    def test_health_readers_preserve_snapshot_values
      health = Julewire::Core::Diagnostics::Health.new(
        counter_keys: %i[callback_errors lost],
        callback_failure_counter: :callback_errors
      )
      callback_failure = Julewire::Core::Diagnostics::CallbackNotifier.failure("CallbackError", phase: :drop)
      failure = health.record_failure(RuntimeError.new("boom"))
      loss = health.record_loss(reason: :dropped, counter: :lost)
      health.record_callback_failure(callback_failure)
      counts = health.counts
      marker = health.degradation_marker
      degraded = health.degraded?
      historical_degraded = health.degraded?(status_from: :failure_or_loss)
      last_callback_failure = health.last_callback_failure
      last_failure = health.last_failure
      last_loss = health.last_loss

      assert_predicate counts, :frozen?
      assert_equal({ callback_errors: 1, lost: 1, failures: 1 }, counts)
      assert_same loss, marker
      assert_true degraded
      assert_true historical_degraded
      assert_equal callback_failure.to_h, last_callback_failure
      assert_same failure, last_failure
      assert_same loss, last_loss
    end

    def test_health_counts_configure_attempts
      before = Julewire.health.dig(:counts, :configure_attempts)

      Julewire.configure { configure_destination(it, output: StringIO.new) }

      assert_equal before + 1, Julewire.health.dig(:counts, :configure_attempts)
    end

    def test_health_reports_unconfigured_output
      health = Julewire.health

      assert_false health.dig(:pipeline, :configured)
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

    def test_runtime_status_degrades_when_one_of_multiple_destinations_is_degraded
      Julewire.configure do |config|
        configure_destination(config, output: StringIO.new)
        configure_destination(config, name: :failing, output: FailingWriteOutput.new)
      end

      Julewire.emit("mixed destination health")

      health = Julewire.health
      destinations = health.dig(:pipeline, :destinations)

      assert_equal :degraded, health.fetch(:status)
      assert_equal :ok, destinations.dig(:default, :status)
      assert_equal :degraded, destinations.dig(:failing, :status)
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

      assert_false Julewire.flush

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

      assert_false Julewire.flush

      assert_equal :degraded, Julewire.health.dig(:pipeline, :destinations, :default, :status)

      assert_true Julewire.flush
      destination = Julewire.health.dig(:pipeline, :destinations, :default)

      assert_equal :ok, destination.fetch(:status)
      assert_equal 1, destination.dig(:counts, :failures)
      assert_equal "RuntimeError", destination.dig(:last_failure, :class)
    end

    def test_health_reports_integration_failures_without_error_messages
      Julewire.configure { configure_destination(it, output: StringIO.new) }
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

    def test_runtime_status_degrades_when_one_of_multiple_process_integrations_is_degraded
      Julewire.configure { configure_destination(it, output: StringIO.new) }
      Julewire::Core::Diagnostics::ProcessIntegrationHealth.record_success(:worker)
      Julewire::Core::Diagnostics::ProcessIntegrationHealth.record_failure(
        :web,
        RuntimeError.new("secret"),
        action: :emit,
        component: :event_subscriber
      )

      health = Julewire.health

      assert_equal :degraded, health.fetch(:status)
      assert_equal :ok, health.dig(:process_integrations, :worker, :status)
      assert_equal :degraded, health.dig(:process_integrations, :web, :status)
    end

    def test_runtime_health_degrades_for_runtime_integration_failure
      Julewire::Core::Diagnostics::ProcessIntegrationHealth.reset!
      runtime = Julewire::Core::Runtime.new
      runtime.configure { configure_destination(it, output: StringIO.new) }

      assert_equal :ok, runtime.health.fetch(:status)

      runtime.record_integration_failure(:test_core, RuntimeError.new("integration failed"), component: :test)

      health = runtime.health

      assert_equal :degraded, health.fetch(:status)
      assert_equal :degraded, health.dig(:integrations, :test_core, :status)
      assert_equal "RuntimeError", health.dig(:integrations, :test_core, :last_failure, :class)
      assert_equal :test, health.dig(:integrations, :test_core, :last_failure, :component)
    ensure
      runtime&.close
      Julewire::Core::Diagnostics::ProcessIntegrationHealth.reset!
    end

    def test_runtime_health_degrades_for_runtime_boundary_failure
      runtime = Julewire::Core::Runtime.new
      runtime.configure { configure_destination(it, output: StringIO.new) }
      pipeline = runtime.__send__(:runtime_state).pipeline

      with_overridden_singleton_method(pipeline, :emit, proc { |*| raise "runtime boundary failed" }) do
        assert_nil runtime.emit(message: "lost")
      end

      health = runtime.health

      assert_equal :degraded, health.fetch(:status)
      assert_equal :runtime, health.dig(:last_failure, :phase)
      assert_equal :emit, health.dig(:last_failure, :action)
    ensure
      runtime&.close
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

    def test_integration_health_store_success_normalizes_names
      store = Julewire::Core::Diagnostics::IntegrationHealthStore.new

      assert_nil store.record_success("web")

      assert_equal :ok, store.health.dig(:web, :status)
      assert_equal({ failures: 0 }, store.health.dig(:web, :counts))
    end

    def test_integration_health_store_failure_normalizes_names
      store = Julewire::Core::Diagnostics::IntegrationHealthStore.new

      assert_nil store.record_failure("web", RuntimeError.new("secret"), component: :install)

      failure = store.health.dig(:web, :last_failure)

      assert_equal :integration, failure.fetch(:phase)
      assert_equal :web, failure.fetch(:integration)
      assert_equal :install, failure.fetch(:component)
      refute_includes failure, :message
    end

    def test_integration_health_store_invalid_name_records_unknown_failure
      store = Julewire::Core::Diagnostics::IntegrationHealthStore.new

      assert_nil store.record_failure(Object.new, RuntimeError.new("bad integration"))

      unknown = store.health.fetch(:unknown)

      assert_equal :degraded, unknown.fetch(:status)
      assert_equal({ failures: 1 }, unknown.fetch(:counts))
      assert_equal 1, unknown.dig(:counts, :failures)
      assert_equal :unknown, unknown.dig(:last_failure, :integration)
    end

    def test_integration_health_store_counts_concurrent_failures_in_one_entry
      store = Julewire::Core::Diagnostics::IntegrationHealthStore.new
      start = Queue.new
      threads = Array.new(16) do
        safe_thread do
          start.pop
          50.times { store.record_failure(:web, RuntimeError.new("install failed")) }
        end
      end

      16.times { start << true }
      safe_thread_values(threads)

      health = store.health

      assert_equal [:web], health.keys
      assert_equal 800, health.dig(:web, :counts, :failures)
      assert_equal :degraded, health.dig(:web, :status)
    ensure
      threads&.each { cleanup_thread(it) }
    end

    def test_integration_health_store_health_snapshot_survives_reset
      store = Julewire::Core::Diagnostics::IntegrationHealthStore.new
      store.record_failure(:web, RuntimeError.new("boom"))

      snapshot = store.health
      result = store.reset!

      assert_nil result
      assert_predicate snapshot, :frozen?
      assert_equal :degraded, snapshot.dig(:web, :status)
      assert_equal({ failures: 1 }, snapshot.dig(:web, :counts))
      assert_empty store.health
    end

    def test_process_integration_health_reset_clears_recorded_entries
      health = Julewire::Core::Diagnostics::ProcessIntegrationHealth
      health.record_failure(:web, RuntimeError.new("boom"))

      assert_nil health.reset!
      assert_empty health.health
    ensure
      health&.reset!
    end
  end
end
