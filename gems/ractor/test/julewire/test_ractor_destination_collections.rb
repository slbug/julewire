# frozen_string_literal: true

require "test_helper"
require_relative "support/bridge_test_values"

module Julewire
  class TestRactorDestinationQueueSlots < Minitest::Test
    cover "Julewire::Ractor::Destination::QueueSlots#initialize"
    cover "Julewire::Ractor::Destination::QueueSlots#value"
    cover "Julewire::Ractor::Destination::QueueSlots#reserve"
    cover "Julewire::Ractor::Destination::QueueSlots#release"

    def test_bounded_slots_reserve_up_to_capacity_and_release_in_order
      slots = queue_slots(max_queue: 2)

      assert_true slots.reserve
      assert_true slots.reserve
      assert_false slots.reserve
      assert_equal 2, slots.value

      assert_false slots.release
      assert_equal 1, slots.value
      assert_false slots.release
      assert_equal 0, slots.value
      assert_true slots.release
      assert_equal 0, slots.value
    end

    def test_unbounded_slots_do_not_track_reservations_or_underflow
      slots = queue_slots(max_queue: 0)

      3.times { assert_true slots.reserve }

      assert_equal 0, slots.value
      assert_false slots.release
      assert_equal 0, slots.value
    end

    private

    def queue_slots(max_queue:)
      Julewire::Ractor::Destination.const_get(:QueueSlots, false).new(max_queue: max_queue)
    end
  end

  class TestRactorDestinationConcurrentQueue < Minitest::Test
    cover "Julewire::Ractor::Destination#emit"
    cover "Julewire::Ractor::Destination#enqueue"
    cover "Julewire::Ractor::Destination#handle_ack"
    cover "Julewire::Ractor::Destination#release_slot"
    cover "Julewire::Ractor::Destination::QueueSlots#reserve"
    include RactorRecordHelper
    include RactorWaitHelper

    def test_ractor_destination_reserves_queue_slots_across_concurrent_emitters
      accepted, dropped = exercise_concurrent_queue

      assert_includes %w[concurrent-0 concurrent-1], accepted
      assert_equal [:queue_full_dropped], dropped
      assert_equal 2, Array(accepted).size + dropped.size
    end

    def test_ractor_destination_unbounded_queue_ack_does_not_count_slot_underflow
      port = ::Ractor::Port.new
      destination = Julewire::Ractor::Destination.new(output: RactorPortOutput.new(port), max_queue: 0)

      destination.emit(record(message: "unbounded"))

      assert_true destination.flush(timeout: 1)
      messages = [receive_ractor(port), receive_ractor(port)]

      assert_equal "unbounded", JSON.parse(messages.find { it.is_a?(String) }).fetch("message")
      wait_until { destination.health.dig(:counts, :worker_accepted) == 1 }
      health = destination.health

      assert_equal 0, health.fetch(:in_flight)
      assert_equal 0, health.dig(:counts, :slot_underflow_ignored)
    ensure
      cleanup_ractor_destination(destination)
      Julewire::Ractor::PortLifecycle.close(port) if port
    end

    def test_ractor_destination_reports_duplicate_worker_acknowledgements
      port = ::Ractor::Port.new
      destination = Julewire::Ractor::Destination.new(output: RactorPortOutput.new(port), max_queue: 1)

      assert_nil destination.emit(record(message: "duplicate-ack"))
      assert_true destination.flush(timeout: 1)
      2.times { receive_ractor(port) }
      wait_until { destination.health.dig(:counts, :worker_accepted) == 1 }

      assert_nil destination.emit(record(message: "uncopyable", payload: { callable: proc {} }))
      assert_equal :degraded, destination.health.fetch(:status)

      destination.instance_variable_get(:@ack_port).send(
        { degradation_marker: nil, event: :ack, status: :accepted }
      )
      wait_until { destination.health.dig(:counts, :slot_underflow_ignored) == 1 }
      health = destination.health

      assert_equal 0, health.fetch(:in_flight)
      assert_equal 2, health.dig(:counts, :worker_accepted)
      assert_equal 1, health.dig(:counts, :slot_underflow_ignored)
      assert_equal :degraded, health.fetch(:status)
      assert_equal :send_error, health.dig(:last_loss, :reason)
    ensure
      cleanup_ractor_destination(destination)
      Julewire::Ractor::PortLifecycle.close(port) if port
    end

    def test_accepted_write_recovers_queue_capacity_health_without_erasing_loss
      port = ::Ractor::Port.new
      destination = Julewire::Ractor::Destination.new(
        output: SlowRactorPortOutput.new(port, sleep_seconds: 0.01),
        max_queue: 1,
        request_timeout: 1
      )

      assert_nil destination.emit(record(message: "first"))
      assert_equal "first", JSON.parse(receive_ractor(port)).fetch("message")
      assert_nil destination.emit(record(message: "dropped"))
      assert_equal :degraded, destination.health.fetch(:status)
      wait_until { destination.health.dig(:counts, :worker_accepted) == 1 }

      assert_nil destination.emit(record(message: "recovered"))
      assert_equal "recovered", JSON.parse(receive_ractor(port)).fetch("message")
      wait_until { destination.health.dig(:counts, :worker_accepted) == 2 }
      health = destination.health

      assert_equal :ok, health.fetch(:status)
      assert_equal :queue_full_dropped, health.dig(:last_loss, :reason)
      assert_equal 1, health.dig(:counts, :queue_full_dropped)
    ensure
      cleanup_ractor_destination(destination)
      Julewire::Ractor::PortLifecycle.close(port) if port
    end

    private

    def concurrent_queue_destination(sleep_seconds:)
      write_port = ::Ractor::Port.new
      drops = Queue.new
      destination = Julewire::Ractor::Destination.new(
        output: SlowRactorPortOutput.new(write_port, sleep_seconds: sleep_seconds),
        max_queue: 1,
        request_timeout: 0.01,
        on_drop: ->(reason, _metadata) { drops << reason }
      )
      [write_port, drops, destination]
    end

    def start_concurrent_emitters(destination)
      completed = false
      ready = Queue.new
      start = Queue.new
      threads = Array.new(2) do |index|
        safe_thread do
          ready << true
          start.pop
          destination.emit(record(message: "concurrent-#{index}"))
        end
      end
      2.times { safe_queue_pop(ready) }
      2.times { start << true }
      safe_thread_values(threads)
      completed = true
      threads
    ensure
      2.times { start&.push(true) } unless completed
      safe_thread_values(threads) if threads && !completed
    end

    def exercise_concurrent_queue(sleep_seconds: 0.5)
      write_port, drops, destination = concurrent_queue_destination(sleep_seconds: sleep_seconds)
      threads = start_concurrent_emitters(destination)
      accepted = JSON.parse(receive_ractor(write_port)).fetch("message")

      assert_equal 1, destination.health.dig(:counts, :queue_full_dropped)

      [accepted, nonblocking_queue_values(drops)]
    ensure
      threads&.each { cleanup_thread(it) }
      cleanup_ractor_destination(destination)
      Julewire::Ractor::PortLifecycle.close(write_port) if write_port
    end
  end

  class TestRactorDestinationFanout < Minitest::Test
    cover Julewire::Ractor::Fanout
    cover "Julewire::Ractor.fanout"
    include RactorRecordHelper

    class DestinationProbe
      attr_reader :before_fork_timeout, :close_timeout, :emitted, :flush_timeout, :forks, :health_calls, :name
      attr_writer :before_fork_error, :before_fork_result, :emit_error, :flush_error, :fork_error, :fork_order

      def initialize(
        name:,
        emit_error: nil,
        flush_error: nil,
        flush_result: true,
        close_error: nil,
        close_result: true,
        health_error: nil,
        fork_error: nil
      )
        @name = name
        @emit_error = emit_error
        @flush_error = flush_error
        @flush_result = flush_result
        @close_error = close_error
        @close_result = close_result
        @health_error = health_error
        @fork_error = fork_error
        @before_fork_result = true
        @emitted = []
        @forks = 0
        @health_calls = 0
      end

      def emit(record)
        raise @emit_error if @emit_error

        @emitted << record
        nil
      end

      def flush(timeout: nil)
        @flush_timeout = timeout
        raise @flush_error if @flush_error

        @flush_result
      end

      def close(timeout: nil)
        @close_timeout = timeout
        raise @close_error if @close_error

        @close_result
      end

      def after_fork!
        raise @fork_error if @fork_error

        @fork_order << name if @fork_order
        @forks += 1
        self
      end

      def before_fork!(timeout: nil)
        @before_fork_timeout = timeout
        raise @before_fork_error if @before_fork_error

        @before_fork_result
      end

      def health
        @health_calls += 1
        raise @health_error if @health_error

        { status: :ok }
      end
    end

    class NoForkDestinationProbe < DestinationProbe
      undef_method :after_fork!
    end

    class NoBeforeForkDestinationProbe < DestinationProbe
      undef_method :before_fork!
    end

    def test_ractor_fanout_defaults_name_and_resource_identity
      fanout = Julewire::Ractor::Fanout.new(destinations: [DestinationProbe.new(name: :worker)])

      assert_equal :ractor_fanout, fanout.name
      assert_same fanout, fanout.resource_identity
    end

    def test_ractor_fanout_sends_record_to_each_worker_destination
      first_port = ::Ractor::Port.new
      second_port = ::Ractor::Port.new
      fanout = Julewire::Ractor.fanout(
        name: :custom_fanout,
        destinations: [
          { name: :first, output: RactorPortOutput.new(first_port) },
          { name: :second, output: RactorPortOutput.new(second_port) }
        ]
      )
      Julewire.configure { it.destinations.add(fanout) }

      safe_thread_value(
        safe_thread { Julewire.emit(message: "parallel-fanout", event: "ractor.fanout") },
        timeout: 0.1
      )

      assert_true fanout.flush(timeout: 1)

      assert_equal "parallel-fanout", port_record(first_port).fetch("message")
      assert_equal "parallel-fanout", port_record(second_port).fetch("message")
      assert_equal :custom_fanout, fanout.name
      assert_equal :ok, fanout.health.fetch(:status)
      assert_equal %i[first second], fanout.health.fetch(:destinations).keys
    ensure
      fanout&.close(timeout: 1)
      Julewire::Ractor::PortLifecycle.close(first_port) if first_port
      Julewire::Ractor::PortLifecycle.close(second_port) if second_port
    end

    def test_ractor_fanout_accepts_hash_subclass_destination_configs
      port = ::Ractor::Port.new
      config = Class.new(Hash).new
      config[:name] = :hash_child
      config[:output] = RactorPortOutput.new(port)
      fanout = Julewire::Ractor::Fanout.new(destinations: [config])

      assert_equal [:hash_child], fanout.health.fetch(:destinations).keys
    ensure
      fanout&.close(timeout: 1)
      Julewire::Ractor::PortLifecycle.close(port) if port
    end

    def test_ractor_fanout_handles_destination_failures
      failures = Queue.new
      good = DestinationProbe.new(name: :good)
      bad = DestinationProbe.new(name: :bad, emit_error: RuntimeError.new("emit failed"))
      fanout = Julewire::Ractor::Fanout.new(
        destinations: [bad, good],
        on_failure: ->(error, metadata) { failures << [error.class, metadata] }
      )
      fanout_record = record(message: "fanout")

      assert_nil fanout.emit(fanout_record)

      health = fanout.health

      assert_equal [fanout_record], good.emitted
      assert_equal :degraded, health.fetch(:status)
      assert_equal :emit, health.dig(:last_failure, :action)
      assert_equal :bad, health.dig(:last_failure, :destination)
      assert_equal :ractor_fanout, health.dig(:last_failure, :phase)
      failure_class, metadata = safe_queue_pop(failures, timeout: 0.1)

      assert_equal RuntimeError, failure_class
      assert_equal :emit, metadata.fetch(:action)
      assert_equal :bad, metadata.fetch(:destination)
      assert_equal :ractor_fanout, metadata.fetch(:phase)
    end

    def test_ractor_fanout_emit_failure_includes_record_metadata
      bad = DestinationProbe.new(name: :bad, emit_error: RuntimeError.new("emit failed"))
      fanout = Julewire::Ractor::Fanout.new(destinations: [bad])
      fanout_record = record(
        message: "fanout",
        event: "ractor.fanout.failed",
        severity: :warn,
        source: "worker",
        labels: { component: "fanout" }
      )

      fanout.emit(fanout_record)
      failure = fanout.health.fetch(:last_failure)

      assert_equal "RuntimeError", failure.fetch(:class)
      assert_equal(
        {
          event: "ractor.fanout.failed",
          labels: { component: "fanout" },
          severity: :warn,
          source: "worker"
        },
        failure.fetch(:record)
      )
    end

    def test_ractor_fanout_failures_do_not_add_generic_failure_counter
      bad = DestinationProbe.new(name: :bad, emit_error: RuntimeError.new("emit failed"))
      fanout = Julewire::Ractor::Fanout.new(destinations: [bad])

      fanout.emit(record(message: "fanout"))

      refute_includes fanout.health.fetch(:counts), :failures
    end

    def test_ractor_fanout_emit_failure_marks_health_degraded_without_callback
      bad = DestinationProbe.new(name: :bad, emit_error: RuntimeError.new("emit failed"))
      fanout = Julewire::Ractor::Fanout.new(destinations: [bad])

      assert_nil fanout.emit(record(message: "fanout"))

      health = fanout.health

      assert_equal :degraded, health.fetch(:status)
      assert_equal :ractor_fanout, health.dig(:last_failure, :phase)
    end

    def test_ractor_fanout_emit_recovery_keeps_failure_history
      destination = DestinationProbe.new(name: :worker, emit_error: RuntimeError.new("emit failed"))
      fanout = Julewire::Ractor::Fanout.new(destinations: [destination])

      assert_nil fanout.emit(record(message: "failed"))
      destination.emit_error = nil
      recovered = record(message: "recovered")

      assert_nil fanout.emit(recovered)
      health = fanout.health

      assert_equal :ok, health.fetch(:status)
      assert_equal :emit, health.dig(:last_failure, :action)
      assert_equal [recovered], destination.emitted
    end

    def test_ractor_fanout_contains_raising_failure_callback
      fanout_record = record(message: "fanout-chaos")
      error = RuntimeError.new("fanout failed")
      bad = DestinationProbe.new(name: :bad, emit_error: error)
      fanout = Julewire::Ractor::Fanout.new(
        destinations: [bad],
        on_failure: ->(*) { raise error }
      )

      assert_nil fanout.emit(fanout_record)

      assert_equal :degraded, fanout.health.fetch(:status)
      assert_equal :ractor_fanout, fanout.health.dig(:last_failure, :phase)
    end

    def test_ractor_fanout_reports_lifecycle_and_health_failures
      bad_lifecycle = DestinationProbe.new(name: :bad_lifecycle, flush_result: false)
      bad_health = DestinationProbe.new(name: :bad_health, health_error: RuntimeError.new("health failed"))
      fanout = Julewire::Ractor::Fanout.new(destinations: [bad_lifecycle, bad_health])

      assert_false fanout.flush(timeout: 1)

      health = fanout.health

      assert_equal 1, bad_lifecycle.flush_timeout
      assert_equal :degraded, health.fetch(:status)
      assert_equal "RuntimeError", health.dig(:destinations, :bad_health, :class)
      assert_equal :bad_health, health.dig(:destinations, :bad_health, :destination)
      assert_equal :ractor_fanout_health, health.dig(:destinations, :bad_health, :phase)
    end

    def test_ractor_fanout_health_reflects_child_degradation
      degraded = DestinationProbe.new(name: :degraded)
      degraded.define_singleton_method(:health) { { status: :degraded } }
      fanout = Julewire::Ractor::Fanout.new(destinations: [degraded])
      health = fanout.health

      assert_equal :degraded, health.fetch(:status)
      assert_equal :degraded, health.dig(:destinations, :degraded, :status)
    end

    def test_ractor_fanout_health_keeps_empty_child_health_ok
      quiet = DestinationProbe.new(name: :quiet)
      quiet.define_singleton_method(:health) { {} }
      fanout = Julewire::Ractor::Fanout.new(destinations: [quiet])
      health = fanout.health

      assert_equal :ok, health.fetch(:status)
      assert_empty health.fetch(:destinations).fetch(:quiet)
    end

    def test_ractor_fanout_health_ignores_nil_child_phase
      quiet = DestinationProbe.new(name: :quiet)
      quiet.define_singleton_method(:health) { { phase: nil } }
      fanout = Julewire::Ractor::Fanout.new(destinations: [quiet])
      health = fanout.health

      assert_equal :ok, health.fetch(:status)
      assert_nil health.dig(:destinations, :quiet, :phase)
    end

    def test_ractor_fanout_lifecycle_records_exceptions
      failures = Queue.new
      bad = DestinationProbe.new(
        name: :bad_lifecycle,
        flush_error: RuntimeError.new("flush failed")
      )
      fanout = Julewire::Ractor::Fanout.new(
        destinations: [bad],
        on_failure: ->(error, metadata) { failures << [error.class, metadata] }
      )

      assert_false fanout.flush(timeout: 0.5)
      health = fanout.health
      failure_class, metadata = safe_queue_pop(failures, timeout: 0.1)

      assert_in_delta(0.5, bad.flush_timeout)
      assert_equal :degraded, health.fetch(:status)
      assert_equal "RuntimeError", health.dig(:last_failure, :class)
      assert_equal :flush, health.dig(:last_failure, :action)
      assert_equal :bad_lifecycle, health.dig(:last_failure, :destination)
      assert_equal RuntimeError, failure_class
      assert_equal :flush, metadata.fetch(:action)
      assert_equal :bad_lifecycle, metadata.fetch(:destination)
      assert_equal :ractor_fanout, metadata.fetch(:phase)
    end

    def test_ractor_fanout_lifecycle_recovery_keeps_failure_history
      destination = DestinationProbe.new(name: :worker, flush_error: RuntimeError.new("flush failed"))
      fanout = Julewire::Ractor::Fanout.new(destinations: [destination])

      assert_false fanout.flush
      destination.flush_error = nil

      assert_true fanout.flush
      health = fanout.health

      assert_equal :ok, health.fetch(:status)
      assert_equal :flush, health.dig(:last_failure, :action)
    end

    def test_ractor_fanout_lifecycle_defaults_to_nil_timeout_and_forwards_close_timeout
      destination = DestinationProbe.new(name: :worker)
      fanout = Julewire::Ractor::Fanout.new(destinations: [destination])

      assert_true fanout.flush
      assert_true fanout.close
      assert_true fanout.close(timeout: 0.25)

      assert_nil destination.flush_timeout
      assert_in_delta(0.25, destination.close_timeout)
    end

    def test_ractor_fanout_after_fork_forwards_and_contains_failures
      good = DestinationProbe.new(name: :good)
      bad = DestinationProbe.new(name: :bad, fork_error: RuntimeError.new("fork failed"))
      fanout = Julewire::Ractor::Fanout.new(destinations: [good, bad])

      assert_same fanout, fanout.after_fork!

      assert_equal 1, good.forks
      assert_equal :degraded, fanout.health.fetch(:status)
      assert_equal :after_fork, fanout.health.dig(:last_failure, :action)
      assert_equal :bad, fanout.health.dig(:last_failure, :destination)
      assert_equal "RuntimeError", fanout.health.dig(:last_failure, :class)
    end

    def test_ractor_fanout_after_fork_recovery_keeps_failure_history
      destination = DestinationProbe.new(name: :worker, fork_error: RuntimeError.new("fork failed"))
      fanout = Julewire::Ractor::Fanout.new(destinations: [destination])

      assert_same fanout, fanout.after_fork!
      destination.fork_error = nil

      assert_same fanout, fanout.after_fork!
      health = fanout.health

      assert_equal :ok, health.fetch(:status)
      assert_equal :after_fork, health.dig(:last_failure, :action)
      assert_equal 1, destination.forks
    end

    def test_ractor_fanout_after_fork_skips_destinations_without_hook
      destination = NoForkDestinationProbe.new(name: :plain)
      fanout = Julewire::Ractor::Fanout.new(destinations: [destination])

      assert_same fanout, fanout.after_fork!

      assert_equal :ok, fanout.health.fetch(:status)
    end

    def test_ractor_fanout_after_fork_propagates_unsafe_fork_errors
      error = Julewire::Core::UnsafeForkError.new("unsafe")
      destination = DestinationProbe.new(name: :worker, fork_error: error)
      fanout = Julewire::Ractor::Fanout.new(destinations: [destination])

      raised = assert_raises(Julewire::Core::UnsafeForkError) { fanout.after_fork! }

      assert_same error, raised
    end

    def test_ractor_fanout_before_fork_forwards_a_shared_deadline
      first = DestinationProbe.new(name: :first)
      second = DestinationProbe.new(name: :second)
      plain = NoBeforeForkDestinationProbe.new(name: :plain)
      fanout = Julewire::Ractor::Fanout.new(destinations: [first, plain, second])

      assert_same fanout, fanout.before_fork!(timeout: 0.25)

      assert_operator first.before_fork_timeout, :>, 0
      assert_operator first.before_fork_timeout, :<=, 0.25
      assert_operator second.before_fork_timeout, :>, 0
      assert_operator second.before_fork_timeout, :<=, first.before_fork_timeout
      assert_nil plain.before_fork_timeout
    end

    def test_ractor_fanout_before_fork_failure_resumes_prepared_destinations
      order = []
      first = DestinationProbe.new(name: :first)
      second = DestinationProbe.new(name: :second)
      first.fork_order = order
      second.fork_order = order
      second.before_fork_error = RuntimeError.new("unsafe")
      fanout = Julewire::Ractor::Fanout.new(destinations: [first, second])

      error = assert_raises(RuntimeError) { fanout.before_fork! }

      assert_equal "unsafe", error.message
      assert_equal 1, first.forks
      assert_equal 1, second.forks
      assert_equal %i[second first], order
    end

    def test_ractor_fanout_before_fork_preserves_failure_when_rollback_also_fails
      first = DestinationProbe.new(name: :first, fork_error: RuntimeError.new("rollback failed"))
      second = DestinationProbe.new(name: :second)
      second.before_fork_error = RuntimeError.new("unsafe")
      fanout = Julewire::Ractor::Fanout.new(destinations: [first, second])

      error = assert_raises(RuntimeError) { fanout.before_fork! }
      health = fanout.health

      assert_equal "unsafe", error.message
      assert_equal :after_fork, health.dig(:last_failure, :action)
      assert_equal :first, health.dig(:last_failure, :destination)
      assert_equal "RuntimeError", health.dig(:last_failure, :class)
    end

    def test_ractor_fanout_before_fork_rejects_false_and_resumes_attempted_destination
      order = []
      first = DestinationProbe.new(name: :first)
      rejecting = DestinationProbe.new(name: :rejecting)
      first.fork_order = order
      rejecting.fork_order = order
      rejecting.before_fork_result = false
      fanout = Julewire::Ractor::Fanout.new(destinations: [first, rejecting])

      error = assert_raises(Julewire::Core::Error) { fanout.before_fork! }

      assert_equal "destination rejecting rejected before_fork", error.message
      assert_equal %i[rejecting first], order
    end

    def test_ractor_fanout_before_fork_validates_timeout_before_preparing_destinations
      destination = DestinationProbe.new(name: :worker)
      fanout = Julewire::Ractor::Fanout.new(destinations: [destination])

      error = assert_raises(ArgumentError) { fanout.before_fork!(timeout: -1) }

      assert_equal "timeout must be nil or a non-negative finite Numeric", error.message
      assert_nil destination.before_fork_timeout
    end

    def test_ractor_fanout_failure_callbacks_are_contained
      bad = DestinationProbe.new(name: :bad, emit_error: RuntimeError.new("emit failed"))
      fanout = Julewire::Ractor::Fanout.new(
        destinations: [bad],
        on_failure: ->(_error, _metadata) { raise "callback failed" }
      )

      assert_nil fanout.emit(record(message: "fanout"))

      assert_equal :degraded, fanout.health.fetch(:status)
      assert_equal "RuntimeError", fanout.health.dig(:last_failure, :class)
      assert_equal "RuntimeError", fanout.health.dig(:last_callback_failure, :class)
      assert_equal :bad, fanout.health.dig(:last_callback_failure, :destination)
    end

    def test_ractor_fanout_validates_options
      error = assert_raises(ArgumentError) { Julewire::Ractor::Fanout.new(destinations: []) }

      assert_equal "destinations must not be empty", error.message
      error = assert_raises(ArgumentError) do
        Julewire::Ractor::Fanout.new(destinations: DestinationProbe.new(name: :single))
      end
      assert_equal "destinations must be an Array", error.message
      array_subclass = Class.new(Array).new([DestinationProbe.new(name: :ok)])
      error = assert_raises(ArgumentError) do
        Julewire::Ractor::Fanout.new(destinations: array_subclass)
      end
      assert_equal "destinations must be an Array", error.message
      assert_invalid_fanout_name(nil)
      assert_invalid_fanout_name(Object.new)
      assert_invalid_fanout_name("")
      error = assert_raises(ArgumentError) do
        Julewire::Ractor::Fanout.new(destinations: [DestinationProbe.new(name: :ok)], on_failure: Object.new)
      end
      assert_equal "on_failure must respond to #call", error.message
      assert_raises(ArgumentError) { Julewire::Ractor::Fanout.new(destinations: [Object.new]) }
    end

    private

    def assert_invalid_fanout_name(name)
      assert_raises(ArgumentError) { Julewire::Ractor::Fanout.new(destinations: [DestinationProbe.new(name: :ok)], name:) }
    end

    def port_record(port)
      messages = [receive_ractor(port), receive_ractor(port)]
      JSON.parse(messages.find { it.is_a?(String) })
    end
  end

  class TestRactorDestinationSendError < Minitest::Test
    cover "Julewire::Ractor::Destination#emit"
    cover "Julewire::Ractor::Destination#enqueue"
    cover "Julewire::Ractor::Destination#record_loss"
    include DroppingRactorDestinationHelper
    include RactorRecordHelper

    def test_ractor_destination_drops_non_copyable_record_payload_values
      port, drops, destination = dropping_ractor_destination

      safe_thread_value(
        safe_thread { destination.emit(record(message: "bad", payload: { callback: proc {} })) },
        timeout: 0.1
      )
      health = destination.health

      assert_equal 1, health.dig(:counts, :send_error)
      assert_equal 0, health.fetch(:in_flight)
      assert_equal :send_error, health.dig(:last_loss, :reason)
      assert_equal :degraded, health.fetch(:status)
      assert_equal [:send_error], nonblocking_queue_values(drops)
    ensure
      cleanup_ractor_destination(destination)
      Julewire::Ractor::PortLifecycle.close(port) if port
    end
  end
end
