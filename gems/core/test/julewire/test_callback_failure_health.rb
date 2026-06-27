# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestCallbackFailureHealth < Minitest::Test
    cover Julewire::Core::Diagnostics::CallbackNotifier
    cover Julewire::Core::Diagnostics::CallbackNotifier::Failure
    cover Julewire::Core::Integration::DestinationHealth
    cover "Julewire::Core::Integration::DestinationHealth#increment"
    class FailingOutput
      def write(_value)
        raise "write failed"
      end
    end

    def test_destination_callback_failures_report_last_context
      Julewire.configure do |config|
        configure_destination(config, output: FailingOutput.new)
        config.on_failure = ->(_error, _metadata) { raise "callback failed" }
      end

      Julewire.emit(message: "output")

      counts = destination_health.fetch(:counts)

      assert_equal 1, counts.fetch(:callback_error)
      assert_equal "RuntimeError", destination_health.dig(:last_callback_failure, :class)
      assert_equal :output, destination_health.dig(:last_callback_failure, :phase)
      assert_equal :default, destination_health.dig(:last_callback_failure, :destination)
    end

    def test_destination_health_snapshot_includes_losses_without_callback_failure
      health = Julewire::Core::Integration::DestinationHealth.new(
        counter_keys: %i[dropped callback_error],
        callback_failure_counter: :callback_error
      )

      loss = health.record_loss(reason: :dropped, route: "orders")
      snapshot = health.snapshot(destination: :default)

      assert_predicate snapshot, :frozen?
      assert_same loss, health.last_loss
      assert_same loss, snapshot.fetch(:last_loss)
      assert_equal :degraded, snapshot.fetch(:status)
      assert_equal :default, snapshot.fetch(:destination)
      assert_equal({ dropped: 1, callback_error: 0, failures: 0 }, snapshot.fetch(:counts))
      refute_includes snapshot, :last_callback_failure
    end

    def test_destination_health_can_route_losses_to_custom_counter
      health = Julewire::Core::Integration::DestinationHealth.new(counter_keys: %i[rejected output_rejected])

      loss = health.record_loss(reason: :output_rejected, counter: :rejected, route: "orders")
      snapshot = health.snapshot(destination: :default)

      assert_same loss, health.last_loss
      assert_same loss, snapshot.fetch(:last_loss)
      assert_equal({ rejected: 1, output_rejected: 0, failures: 0 }, snapshot.fetch(:counts))
      assert_equal :output_rejected, snapshot.dig(:last_loss, :reason)
      assert_equal "orders", snapshot.dig(:last_loss, :route)
    end

    def test_destination_health_increment_honors_custom_amount
      health = Julewire::Core::Integration::DestinationHealth.new(counter_keys: %i[queued])

      health.increment(:queued, by: 3)

      assert_equal 3, health.snapshot.fetch(:counts).fetch(:queued)
    end

    def test_destination_health_increment_defaults_to_one
      health = Julewire::Core::Integration::DestinationHealth.new(counter_keys: %i[queued])

      health.increment(:queued)

      assert_equal 1, health.snapshot.fetch(:counts).fetch(:queued)
    end

    def test_destination_health_degraded_tracks_failures_and_losses
      health = Julewire::Core::Integration::DestinationHealth.new(counter_keys: %i[dropped])

      refute_predicate health, :degraded?

      loss = health.record_loss(reason: :dropped)
      marker = health.degradation_marker
      callback_failure = Julewire::Core::Diagnostics::CallbackNotifier.failure("CallbackError", phase: :write)
      health.record_callback_failure(callback_failure)

      assert_predicate health, :degraded?

      health.clear_degradation_if_unchanged(Object.new)

      assert_predicate health, :degraded?

      health.clear_degradation_if_unchanged(marker)

      refute_predicate health, :degraded?
      assert_same loss, health.last_loss
      assert_equal "CallbackError", health.last_callback_failure.fetch(:class)

      failure = health.record_failure(RuntimeError.new("write failed"))

      assert_predicate health, :degraded?
      assert_same failure, health.last_failure

      health.clear_failures!

      refute_predicate health, :degraded?
      assert_nil health.last_failure
      assert_nil health.last_loss
      assert_nil health.last_callback_failure
    end

    def test_destination_health_recovers_only_a_successful_unchanged_operation
      health = Julewire::Core::Integration::DestinationHealth.new(counter_keys: [])
      first_loss = health.record_loss(reason: :first, counter: nil)

      false_result = health.recover_if_successful { false }

      assert_false false_result
      assert_same first_loss, health.degradation_marker

      second_loss = nil
      result = health.recover_if_successful do
        second_loss = health.record_loss(reason: :second, counter: nil)
        nil
      end

      assert_nil result
      assert_same second_loss, health.degradation_marker

      true_result = health.recover_if_successful { true }

      assert_true true_result
      refute_predicate health, :degraded?
      assert_same second_loss, health.last_loss
    end

    def test_destination_health_can_route_failures_to_custom_counter
      health = Julewire::Core::Integration::DestinationHealth.new(
        counter_keys: [:write_errors],
        failure_counter: :write_errors
      )

      failure = health.record_failure(RuntimeError.new("write failed"), phase: :write)
      snapshot = health.snapshot(destination: :default)

      assert_same failure, health.last_failure
      assert_equal :degraded, snapshot.fetch(:status)
      assert_equal({ write_errors: 1 }, snapshot.fetch(:counts))
      assert_equal "RuntimeError", snapshot.dig(:last_failure, :class)
      assert_equal :write, snapshot.dig(:last_failure, :phase)
    end

    def test_callback_notifier_failure_compacts_metadata_and_uses_utc_timestamp
      failure = Julewire::Core::Diagnostics::CallbackNotifier.failure(
        "CallbackError",
        action: :emit,
        destination: nil,
        phase: :write,
        reason: :callback_raised
      )
      snapshot = failure.to_h

      assert_instance_of Time, snapshot.fetch(:at)
      assert_equal 0, snapshot.fetch(:at).utc_offset
      assert_equal "CallbackError", snapshot.fetch(:class)
      assert_equal :emit, snapshot.fetch(:action)
      assert_equal :write, snapshot.fetch(:phase)
      assert_equal :callback_raised, snapshot.fetch(:reason)
      assert_predicate snapshot, :frozen?
      refute_includes snapshot, :destination
    end

    def test_callback_notifier_failure_defaults_nil_metadata_to_empty_hash
      snapshot = Julewire::Core::Diagnostics::CallbackNotifier.failure("CallbackError", nil).to_h

      assert_equal "CallbackError", snapshot.fetch(:class)
      assert_instance_of Time, snapshot.fetch(:at)
      refute_includes snapshot, :action
      refute_includes snapshot, :destination
      refute_includes snapshot, :phase
      refute_includes snapshot, :reason
    end

    def test_nested_callback_result_uses_public_class_name_string
      snapshot = Julewire::Core::Diagnostics::CallbackNotifier.nested_callback_result(
        destination: :default,
        phase: :drop
      ).to_h

      assert_equal "Julewire::Core::Diagnostics::CallbackNotifier::NestedCallback", snapshot.fetch(:class)
      assert_equal :default, snapshot.fetch(:destination)
      assert_equal :drop, snapshot.fetch(:phase)
    end

    def test_destination_health_snapshot_merges_callback_failure_and_fields
      health = Julewire::Core::Integration::DestinationHealth.new(
        counter_keys: %i[dropped callback_error],
        callback_failure_counter: :callback_error
      )
      callback_failure = Julewire::Core::Diagnostics::CallbackNotifier.failure(
        "CallbackError",
        destination: :default,
        phase: :drop
      )

      health.record_callback_failure(callback_failure)
      snapshot = health.snapshot(status: :closed, destination: :default)

      assert_predicate snapshot, :frozen?
      assert_equal :closed, snapshot.fetch(:status)
      assert_equal :default, snapshot.fetch(:destination)
      assert_equal({ dropped: 0, callback_error: 1, failures: 0 }, snapshot.fetch(:counts))
      assert_equal callback_failure.to_h, snapshot.fetch(:last_callback_failure)
    end
  end
end
