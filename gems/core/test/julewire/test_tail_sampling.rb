# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestTailSampling < Minitest::Test
    cover Julewire::Core::Destinations::TailSampling

    class CapturingDestination
      attr_reader :records, :name

      def initialize(name = :capture)
        @name = name
        @records = []
        @flushed = false
        @closed = false
      end

      def emit(record)
        @records << record
        nil
      end

      def flush(timeout: nil) # rubocop:disable Naming/PredicateMethod -- Destination protocol uses truthy lifecycle results.
        @flushed = timeout
        true
      end

      def close(timeout: nil) # rubocop:disable Naming/PredicateMethod -- Destination protocol uses truthy lifecycle results.
        @closed = timeout
        true
      end

      def health
        { status: :ok, flushed: @flushed, closed: @closed }
      end
    end

    class ForkingDestination < CapturingDestination
      attr_reader :forks

      def initialize
        super(:forking)
        @forks = 0
      end

      def after_fork!
        @forks += 1
        self
      end
    end

    class RaisingDestination
      attr_reader :name

      def initialize(name = :raising)
        @name = name
      end

      def emit(_record)
        raise "emit failed"
      end

      def flush(timeout: nil)
        raise "flush failed for #{timeout.inspect}"
      end

      def close(timeout: nil)
        raise "close failed for #{timeout.inspect}"
      end

      def health
        raise "health failed"
      end
    end

    def test_tail_sampling_drops_unsampled_execution
      destination = CapturingDestination.new
      sampler = Julewire::TailSampling.new(destination: destination, sample_rate: 0)
      Julewire.configure { it.destinations.add(sampler) }

      Julewire.with_execution(type: :request, id: "request-1") do
        Julewire.info("point")
      end

      assert_empty destination.records
      assert_equal 2, sampler.health.dig(:counts, :policy_dropped)
      assert_equal :ok, sampler.health.fetch(:status)
    end

    def test_tail_sampling_keeps_error_execution
      destination = CapturingDestination.new
      sampler = Julewire::TailSampling.new(destination: destination, sample_rate: 0)
      Julewire.configure { it.destinations.add(sampler) }

      assert_raises(RuntimeError) do
        Julewire.with_execution(type: :request, id: "request-2") do
          Julewire.info("point")
          raise "boom"
        end
      end

      messages = destination.records.map { display_message(it) }
      kinds = destination.records.map { it.fetch(:kind) }

      assert_equal ["point", "RuntimeError: boom"], messages
      assert_equal %i[point summary], kinds
    end

    def test_tail_sampling_keeps_slow_execution
      destination = CapturingDestination.new
      sampler = Julewire::TailSampling.new(destination: destination, sample_rate: 0, slow_ms: 0)
      Julewire.configure { it.destinations.add(sampler) }

      Julewire.with_execution(type: :request, id: "request-3") do
        Julewire.info("point")
      end

      kinds = destination.records.map { it.fetch(:kind) }
      messages = destination.records.take(1).map { display_message(it) }

      assert_equal %i[point summary], kinds
      assert_equal ["point"], messages
    end

    def test_tail_sampling_accepts_custom_decider
      destination = CapturingDestination.new
      sampler = Julewire::TailSampling.new(
        destination: destination,
        decider: ->(record, key:) { key.last == "request-keep" && record[:kind] == :summary },
        sample_rate: 0
      )
      Julewire.configure { it.destinations.add(sampler) }

      Julewire.with_execution(type: :request, id: "request-drop") { Julewire.info("dropped") }
      Julewire.with_execution(type: :request, id: "request-keep") { Julewire.info("kept") }

      messages = destination.records.map { display_message(it) }
      events = destination.records.map { it.fetch(:event) }

      assert_equal ["kept", nil], messages
      assert_equal ["log", "request.completed"], events
      assert_equal 2, sampler.health.dig(:counts, :emitted)
    end

    def test_tail_sampling_contains_decider_failure
      failures = []
      destination = CapturingDestination.new
      sampler = Julewire::TailSampling.new(
        destination: destination,
        decider: ->(_record, key:) { raise "bad policy for #{key.inspect}" },
        on_failure: ->(error, **metadata) { failures << [error.message, metadata.fetch(:phase)] }
      )
      Julewire.configure { it.destinations.add(sampler) }

      Julewire.with_execution(type: :request, id: "request-1") { Julewire.info("point") }

      assert_empty destination.records
      assert_equal [["bad policy for [\"request\", \"request-1\"]", :tail_sampling_decider]], failures
      assert_equal :tail_sampling_decider, sampler.health.dig(:last_failure, :phase)
    end

    def test_tail_sampling_emits_unscoped_records_immediately
      destination = CapturingDestination.new
      sampler = Julewire::TailSampling.new(destination: destination, sample_rate: 0)
      Julewire.configure { it.destinations.add(sampler) }

      Julewire.info("outside")

      messages = destination.records.map { display_message(it) }

      assert_equal ["outside"], messages
      assert_equal 1, sampler.health.dig(:counts, :immediate)
    end

    def test_tail_sampling_flushes_pending_records
      destination = CapturingDestination.new
      sampler = Julewire::TailSampling.new(destination: destination, sample_rate: 0)
      record = build_record({ message: "pending", execution: { type: :job, id: "job-1" } })

      sampler.emit(record)

      assert_empty destination.records

      assert sampler.flush(timeout: 1)

      messages = destination.records.map { display_message(it) }

      assert_equal ["pending"], messages
      assert_equal 1, sampler.health.dig(:counts, :emitted)
    end

    def test_tail_sampling_overflow_drops_oldest_execution
      drops = []
      destination = CapturingDestination.new
      sampler = Julewire::TailSampling.new(
        destination: destination,
        sample_rate: 1,
        max_executions: 1,
        on_drop: ->(reason, _metadata) { drops << reason }
      )

      sampler.emit(build_record({ message: "first", execution: { type: :job, id: "job-1" } }))
      sampler.emit(build_record({ message: "second", execution: { type: :job, id: "job-2" } }))

      assert_equal [:overflow_dropped], drops
      assert_equal :degraded, sampler.health.fetch(:status)
      assert_equal 1, sampler.health.dig(:counts, :overflow_dropped)
    end

    def test_tail_sampling_caps_records_per_execution
      destination = CapturingDestination.new
      sampler = Julewire::TailSampling.new(
        destination: destination,
        sample_rate: 1,
        max_records_per_execution: 1
      )

      sampler.emit(build_record({ message: "first", execution: { type: :job, id: "job-1" } }))
      sampler.emit(build_record({ message: "second", execution: { type: :job, id: "job-1" } }))
      sampler.emit(build_record({ kind: :summary, message: "done", execution: { type: :job, id: "job-1" } }))

      messages = destination.records.map { display_message(it) }

      assert_equal %w[second done], messages
      assert_equal 1, sampler.health.dig(:counts, :overflow_dropped)
      assert_equal :degraded, sampler.health.fetch(:status)
    end

    def test_tail_sampling_after_fork_resets_buffers_and_forwards_when_supported
      destination = ForkingDestination.new
      sampler = Julewire::TailSampling.new(destination: destination, sample_rate: 1)
      sampler.emit(build_record({ message: "pending", execution: { type: :job, id: "job-1" } }))

      assert_same sampler, sampler.after_fork!
      assert_equal 1, destination.forks
      assert_equal 0, sampler.health.fetch(:buffered_executions)

      plain_sampler = Julewire::TailSampling.new(destination: CapturingDestination.new, sample_rate: 1)

      assert_same plain_sampler, plain_sampler.after_fork!
    end

    def test_tail_sampling_records_destination_failures_and_health_failures
      failures = []
      sampler = Julewire::TailSampling.new(
        destination: RaisingDestination.new,
        sample_rate: 1,
        on_failure: ->(error, **metadata) { failures << [error.class, metadata] }
      )

      sampler.emit(build_record({ event: "tail.emit", message: "lost" }))

      refute sampler.flush(timeout: 1)

      health = sampler.health

      assert_equal :degraded, health.fetch(:status)
      assert_equal :tail_sampling_lifecycle, health.dig(:last_failure, :phase)
      assert_equal :flush, health.dig(:last_failure, :action)
      assert_equal :tail_sampling_health, health.dig(:destination, :phase)
      assert_equal RuntimeError, failures.first.first
      assert_equal :tail_sampling_destination, failures.first.last.fetch(:phase)
    end

    def test_tail_sampling_records_failure_without_failure_callback
      sampler = Julewire::TailSampling.new(destination: RaisingDestination.new, sample_rate: 1)

      sampler.emit(build_record({ event: "tail.emit", message: "lost" }))

      assert_equal :tail_sampling_destination, sampler.health.dig(:last_failure, :phase)
    end

    def test_tail_sampling_accepts_hash_records_without_lineage
      destination = CapturingDestination.new
      sampler = Julewire::TailSampling.new(destination: destination, sample_rate: 1)

      sampler.emit({ kind: :point, execution: { id: "raw-1" }, message: "raw" })

      assert sampler.flush

      messages = destination.records.map { it.fetch(:message) }

      assert_equal ["raw"], messages
    end

    def test_tail_sampling_validates_options
      assert_raises_message(ArgumentError, /slow_ms must be a non-negative Numeric/) do
        Julewire::TailSampling.new(destination: CapturingDestination.new, slow_ms: Object.new)
      end

      assert_raises_message(ArgumentError, /slow_ms must be non-negative/) do
        Julewire::TailSampling.new(destination: CapturingDestination.new, slow_ms: -1)
      end

      assert_raises_message(ArgumentError, /destination name must be a String or Symbol/) do
        Julewire::TailSampling.new(destination: CapturingDestination.new, name: nil)
      end

      assert_raises_message(ArgumentError, /destination name must be a String or Symbol/) do
        Julewire::TailSampling.new(destination: CapturingDestination.new, name: Object.new)
      end

      assert_raises_message(ArgumentError, /destination name must not be empty/) do
        Julewire::TailSampling.new(destination: CapturingDestination.new, name: "")
      end

      assert_raises_message(ArgumentError, /decider must respond to #call/) do
        Julewire::TailSampling.new(destination: CapturingDestination.new, decider: Object.new)
      end
    end

    private

    def display_message(record)
      Julewire::Core::Records::DisplayMessage.call(record)
    end
  end
end
