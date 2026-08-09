# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestTailSampling < Minitest::Test
    cover Julewire::TailSampling
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

    class BeforeForkDestination < ForkingDestination
      attr_reader :before_fork_count, :before_fork_timeout

      def initialize
        super
        @before_fork_count = 0
      end

      def before_fork!(timeout: nil)
        @before_fork_count += 1
        @before_fork_timeout = timeout
        self
      end
    end

    class RejectingPreparationDestination < BeforeForkDestination
      def before_fork!(timeout: nil) # rubocop:disable Naming/PredicateMethod -- Fork protocol uses false for rejection.
        super
        false
      end
    end

    class RaisingAfterForkDestination < CapturingDestination
      def after_fork!
        raise "after fork failed"
      end
    end

    class UnsafeAfterForkDestination < CapturingDestination
      def after_fork!
        raise Julewire::Core::UnsafeForkError, "unsafe"
      end
    end

    class RejectingBeforeForkDestination < CapturingDestination
      def initialize
        super
        @flush_result = false
      end

      def before_fork!(**) = self
      def flush(**) = @flush_result
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

    class NilLifecycleDestination < CapturingDestination
      def flush(timeout: nil)
        super
        nil
      end

      def close(timeout: nil)
        super
        nil
      end
    end

    class BrokenLineageRecord
      def lineage
        raise "bad lineage"
      end
    end

    Lineage = Data.define(:root_reference)

    class RaisingKindRecord
      attr_reader :lineage

      def initialize
        @lineage = Lineage.new({ type: :job, id: "job-1" })
      end

      def [](key)
        raise "kind failed" if key == :kind

        { event: "tail.pending", severity: :warn, source: "test" }[key]
      end

      def key?(_key) = true
    end

    class LineageBackedRecord
      attr_reader :lineage

      def initialize(kind:, message:, execution:, root_reference:)
        @kind = kind
        @message = message
        @execution = execution
        @lineage = Lineage.new(root_reference)
      end

      def [](key)
        case key
        when :execution then @execution
        when :kind then @kind
        when :message then @message
        end
      end
    end

    class IndexOnlyRecord
      def initialize(kind:, execution:, message:, error: nil, severity: nil)
        @error = error
        @kind = kind
        @execution = execution
        @message = message
        @severity = severity
      end

      def [](key)
        case key
        when :error then @error
        when :execution then @execution
        when :kind then @kind
        when :message then @message
        when :severity then @severity
        end
      end
    end

    def test_tail_sampling_symbolic_factory_configures_real_destination
      destination = CapturingDestination.new(:nested)

      Julewire.configure do |config|
        config.destinations.use(
          :tail_sampling,
          destination: destination,
          sample_rate: 1
        )
      end
      Julewire.with_execution(type: :request, id: "factory-request") do
        Julewire.info("sampled point")
      end

      kinds = destination.records.map { it.fetch(:kind) }

      assert_equal %i[point summary], kinds
      assert_equal "sampled point", display_message(destination.records.fetch(0))
    end

    def test_tail_sampling_drops_unsampled_execution
      destination = CapturingDestination.new
      sampler = Julewire::TailSampling.new(destination: destination, sample_rate: 0)
      Julewire.configure { it.destinations.add(sampler) }

      Julewire.with_execution(type: :request, id: "request-1") do
        Julewire.info("point")
      end

      assert_empty destination.records
      assert_equal 2, sampler.health.dig(:counts, :received)
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

    def test_tail_sampling_keeps_summary_with_error_even_when_severity_is_info
      destination = CapturingDestination.new
      sampler = Julewire::TailSampling.new(destination: destination, sample_rate: 0)
      point = {
        execution: { type: "job", id: "job-error" },
        kind: :point,
        message: "point",
        severity: :info
      }
      summary = {
        error: { class: "RuntimeError", message: "boom" },
        execution: { type: "job", id: "job-error" },
        kind: :summary,
        message: "done",
        severity: :info
      }

      sampler.emit(point)
      sampler.emit(summary)

      assert_equal [point, summary], destination.records
      assert_equal 2, sampler.health.dig(:counts, :emitted)
    end

    def test_tail_sampling_accepts_summary_without_buffered_points
      destination = CapturingDestination.new
      sampler = Julewire::TailSampling.new(destination: destination, sample_rate: 1)
      summary = {
        execution: { type: "job", id: "job-summary-only" },
        kind: :summary,
        message: "done",
        severity: :info
      }

      sampler.emit(summary)

      assert_equal [summary], destination.records
      assert_equal 1, sampler.health.dig(:counts, :emitted)
      assert_nil sampler.health[:last_failure]
    end

    def test_tail_sampling_keeps_error_severity_summary_without_error_field
      assert_tail_sampling_keeps_summary_without_error_field(:error)
    end

    def test_tail_sampling_keeps_fatal_severity_summary_without_error_field
      assert_tail_sampling_keeps_summary_without_error_field(:fatal)
    end

    def assert_tail_sampling_keeps_summary_without_error_field(severity)
      destination = CapturingDestination.new
      sampler = Julewire::TailSampling.new(destination: destination, sample_rate: 0)
      suffix = severity.to_s
      point = {
        execution: { type: "job", id: "job-#{suffix}-severity" },
        kind: :point,
        message: "point-#{suffix}",
        severity: :info
      }
      summary = {
        execution: { type: "job", id: "job-#{suffix}-severity" },
        kind: :summary,
        message: "done-#{suffix}",
        severity: severity
      }

      sampler.emit(point)
      sampler.emit(summary)

      assert_equal [point, summary], destination.records
      assert_equal 2, sampler.health.dig(:counts, :emitted)
    end

    def test_tail_sampling_drops_malformed_summary_severity_without_failure
      destination = CapturingDestination.new
      sampler = Julewire::TailSampling.new(destination: destination, sample_rate: 0)

      sampler.emit(
        {
          execution: { type: "job", id: "job-bad-severity" },
          kind: :point,
          message: "point",
          severity: :info
        }
      )
      sampler.emit(
        {
          execution: { type: "job", id: "job-bad-severity" },
          kind: :summary,
          message: "done",
          severity: Object.new
        }
      )

      assert_empty destination.records
      assert_nil sampler.health[:last_failure]
      assert_equal 2, sampler.health.dig(:counts, :policy_dropped)
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

    def test_tail_sampling_keeps_execution_at_slow_threshold
      destination = CapturingDestination.new
      sampler = Julewire::TailSampling.new(destination: destination, sample_rate: 0, slow_ms: 12)

      sampler.emit(build_record({ message: "point", execution: { type: :job, id: "job-1" } }))
      sampler.emit(
        build_record({
                       kind: :summary,
                       message: "done",
                       execution: { type: :job, id: "job-1" },
                       metrics: { duration_ms: 12 }
                     })
      )

      assert_equal(%w[point done], destination.records.map { display_message(it) })
    end

    def test_tail_sampling_drops_execution_below_slow_threshold
      destination = CapturingDestination.new
      sampler = Julewire::TailSampling.new(destination: destination, sample_rate: 0, slow_ms: 12)

      sampler.emit(build_record({ message: "point", execution: { type: :job, id: "job-1" } }))
      sampler.emit(
        build_record({
                       kind: :summary,
                       message: "done",
                       execution: { type: :job, id: "job-1" },
                       metrics: { duration_ms: 11 }
                     })
      )

      assert_empty destination.records
      assert_equal 2, sampler.health.dig(:counts, :policy_dropped)
    end

    def test_tail_sampling_ignores_nonnumeric_and_missing_slow_metrics
      [
        { duration_ms: "12" },
        nil,
        :absent
      ].each_with_index do |metrics, index|
        destination = CapturingDestination.new
        sampler = Julewire::TailSampling.new(destination: destination, sample_rate: 0, slow_ms: 12)
        execution = { type: :job, id: "job-#{index}" }
        summary = { kind: :summary, message: "done", execution: execution }
        summary[:metrics] = metrics unless metrics == :absent

        sampler.emit(build_record({ message: "point", execution: execution }))
        sampler.emit(build_record(summary))

        assert_empty destination.records
        assert_nil sampler.health[:last_failure]
      end
    end

    def test_tail_sampling_ignores_absent_slow_metrics_on_sparse_hash_summary
      destination = CapturingDestination.new
      sampler = Julewire::TailSampling.new(destination: destination, sample_rate: 0, slow_ms: 12)
      execution = { type: "job", id: "job-raw" }

      sampler.emit({ kind: :point, message: "point", severity: :info, execution: execution })
      sampler.emit({ kind: :summary, message: "done", severity: :info, execution: execution })

      assert_empty destination.records
      assert_equal 2, sampler.health.dig(:counts, :policy_dropped)
      assert_nil sampler.health[:last_failure]
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
        on_failure: lambda { |error, **metadata|
          failures << [error.message, metadata.fetch(:phase), metadata.dig(:record_metadata, :event)]
        }
      )
      Julewire.configure { it.destinations.add(sampler) }

      Julewire.with_execution(type: :request, id: "request-1") { Julewire.info("point") }

      assert_empty destination.records
      assert_equal [["bad policy for [\"request\", \"request-1\"]", :tail_sampling_decider, "request.completed"]],
                   failures
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
      record = build_record({
                              event: "tail.pending",
                              message: "pending",
                              severity: :warn,
                              execution: { type: :job, id: "job-1" }
                            })

      sampler.emit(record)

      assert_empty destination.records

      assert_true sampler.flush(timeout: 1)

      messages = destination.records.map { display_message(it) }

      assert_equal ["pending"], messages
      assert_equal 1, sampler.health.dig(:counts, :emitted)

      assert_true sampler.flush(timeout: 1)
      assert_equal(["pending"], destination.records.map { display_message(it) })
      assert_equal 1, sampler.health.dig(:counts, :emitted)
    end

    def test_tail_sampling_close_drains_pending_records_and_closes_destination
      destination = CapturingDestination.new
      sampler = Julewire::TailSampling.new(destination: destination, sample_rate: 0)
      record = build_record({
                              event: "tail.pending",
                              message: "pending",
                              severity: :warn,
                              execution: { type: :job, id: "job-1" }
                            })

      sampler.emit(record)

      assert_empty destination.records

      assert_true sampler.close(timeout: 2)

      messages = destination.records.map { display_message(it) }

      assert_equal ["pending"], messages
      assert_equal 1, sampler.health.dig(:counts, :emitted)
      assert_equal({ status: :ok, flushed: false, closed: 2 }, sampler.health.fetch(:destination))
    end

    def test_tail_sampling_close_accepts_no_timeout
      destination = CapturingDestination.new
      sampler = Julewire::TailSampling.new(destination: destination, sample_rate: 0)

      assert_true sampler.close

      assert_equal({ status: :ok, flushed: false, closed: nil }, sampler.health.fetch(:destination))
    end

    def test_tail_sampling_lifecycle_treats_nil_as_success
      destination = NilLifecycleDestination.new
      sampler = Julewire::TailSampling.new(destination: destination, sample_rate: 0)

      assert_true sampler.flush(timeout: 1)
      assert_true sampler.close(timeout: 2)

      assert_equal({ status: :ok, flushed: 1, closed: 2 }, sampler.health.fetch(:destination))
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

      sampler.emit(build_record({ event: "first.event", message: "first", execution: { type: :job, id: "job-1" } }))
      sampler.emit(build_record({ event: "second.event", message: "second", execution: { type: :job, id: "job-2" } }))

      assert_equal [:overflow_dropped], drops
      assert_equal :degraded, sampler.health.fetch(:status)
      assert_equal 1, sampler.health.dig(:counts, :overflow_dropped)
      assert_instance_of Hash, sampler.health.dig(:last_loss, :record_metadata)
      assert_equal "first.event", sampler.health.dig(:last_loss, :record_metadata, :event)
      assert_equal :info, sampler.health.dig(:last_loss, :record_metadata, :severity)
    end

    def test_tail_sampling_capacity_drops_oldest_only_after_limit_is_reached
      drops = []
      destination = CapturingDestination.new
      sampler = Julewire::TailSampling.new(
        destination: destination,
        sample_rate: 1,
        max_executions: 2,
        on_drop: ->(reason, metadata) { drops << [reason, metadata.dig(:record_metadata, :event)] }
      )

      sampler.emit(build_record({ event: "first.event", message: "first", execution: { type: :job, id: "job-1" } }))
      sampler.emit(build_record({ event: "second.event", message: "second", execution: { type: :job, id: "job-2" } }))
      sampler.emit(build_record({ event: "third.event", message: "third", execution: { type: :job, id: "job-3" } }))

      assert_equal [[:overflow_dropped, "first.event"]], drops
      assert_equal 1, sampler.health.dig(:counts, :overflow_dropped)

      assert_true sampler.flush(timeout: 1)
      assert_equal(%w[second third], destination.records.map { display_message(it) })
    end

    def test_tail_sampling_does_not_evict_existing_execution_at_capacity
      destination = CapturingDestination.new
      sampler = Julewire::TailSampling.new(
        destination: destination,
        sample_rate: 1,
        max_executions: 1,
        max_records_per_execution: 3
      )

      sampler.emit(build_record({ message: "first", execution: { type: :job, id: "job-1" } }))
      sampler.emit(build_record({ message: "second", execution: { type: :job, id: "job-1" } }))
      sampler.emit(build_record({ kind: :summary, message: "done", execution: { type: :job, id: "job-1" } }))

      assert_equal(%w[first second done], destination.records.map { display_message(it) })
      assert_equal 0, sampler.health.dig(:counts, :overflow_dropped)
      assert_equal :ok, sampler.health.fetch(:status)
    end

    def test_tail_sampling_removes_finished_execution_from_eviction_order
      drops = []
      destination = CapturingDestination.new
      sampler = Julewire::TailSampling.new(
        destination: destination,
        sample_rate: 1,
        max_executions: 1,
        on_drop: ->(reason, metadata) { drops << [reason, metadata.dig(:record_metadata, :event)] }
      )

      sampler.emit(build_record({ event: "first.event", message: "first", execution: { type: :job, id: "job-1" } }))
      sampler.emit(build_record({ kind: :summary, message: "done", execution: { type: :job, id: "job-1" } }))
      sampler.emit(build_record({ event: "second.event", message: "second", execution: { type: :job, id: "job-2" } }))
      sampler.emit(build_record({ event: "third.event", message: "third", execution: { type: :job, id: "job-3" } }))

      assert_true sampler.flush(timeout: 1)

      assert_nil sampler.health[:last_failure]
      assert_equal(%w[first done third], destination.records.map { display_message(it) })
      assert_equal [[:overflow_dropped, "second.event"]], drops
    end

    def test_tail_sampling_caps_records_per_execution
      destination = CapturingDestination.new
      sampler = Julewire::TailSampling.new(
        destination: destination,
        sample_rate: 1,
        max_records_per_execution: 1
      )

      sampler.emit(build_record({ event: "first.event", message: "first", execution: { type: :job, id: "job-1" } }))
      sampler.emit(build_record({ event: "second.event", message: "second", execution: { type: :job, id: "job-1" } }))
      sampler.emit(build_record({ kind: :summary, message: "done", execution: { type: :job, id: "job-1" } }))

      messages = destination.records.map { display_message(it) }

      assert_equal %w[second done], messages
      assert_equal 1, sampler.health.dig(:counts, :overflow_dropped)
      assert_equal :degraded, sampler.health.fetch(:status)
      assert_instance_of Hash, sampler.health.dig(:last_loss, :record_metadata)
      assert_equal "first.event", sampler.health.dig(:last_loss, :record_metadata, :event)
    end

    def test_tail_sampling_cap_drops_oldest_record_when_buffer_already_full
      drops = []
      destination = CapturingDestination.new
      sampler = Julewire::TailSampling.new(
        destination: destination,
        sample_rate: 1,
        max_records_per_execution: 2,
        on_drop: ->(reason, metadata) { drops << [reason, metadata.dig(:record_metadata, :event)] }
      )

      sampler.emit(build_record({ event: "first.event", message: "first", execution: { type: :job, id: "job-1" } }))
      sampler.emit(build_record({ event: "second.event", message: "second", execution: { type: :job, id: "job-1" } }))
      sampler.emit(build_record({ event: "third.event", message: "third", execution: { type: :job, id: "job-1" } }))
      sampler.emit(build_record({ kind: :summary, message: "done", execution: { type: :job, id: "job-1" } }))

      assert_equal(%w[second third done], destination.records.map { display_message(it) })
      assert_equal [[:overflow_dropped, "first.event"]], drops
      assert_equal 3, sampler.health.dig(:counts, :buffered)
      assert_equal 1, sampler.health.dig(:counts, :overflow_dropped)
    end

    def test_tail_sampling_policy_drop_callback_receives_loss_metadata
      drops = []
      destination = CapturingDestination.new
      sampler = Julewire::TailSampling.new(
        destination: destination,
        sample_rate: 0,
        on_drop: ->(reason, metadata) { drops << [reason, metadata.dig(:record_metadata, :event)] }
      )

      sampler.emit(build_record({ event: "point.event", message: "point", execution: { type: :job, id: "job-1" } }))
      sampler.emit(build_record({ kind: :summary, event: "summary.event", message: "done",
                                  execution: { type: :job, id: "job-1" } }))

      assert_empty destination.records
      assert_equal [[:policy_dropped, "point.event"], [:policy_dropped, "summary.event"]], drops
      assert_nil sampler.health[:last_failure]
    end

    def test_tail_sampling_contains_drop_callback_failures
      failures = []
      sampler = Julewire::TailSampling.new(
        destination: CapturingDestination.new,
        max_executions: 1,
        on_drop: ->(_reason, _metadata) { raise "drop callback failed" },
        on_failure: ->(error, **metadata) { failures << [error, metadata] },
        sample_rate: 1
      )

      sampler.emit(build_record({ event: "first.event", message: "first", execution: { type: :job, id: "job-1" } }))
      sampler.emit(build_record({ event: "second.event", message: "second", execution: { type: :job, id: "job-2" } }))

      error, metadata = failures.fetch(0)

      assert_equal "drop callback failed", error.message
      assert_equal :tail_sampling_drop_callback, metadata.fetch(:phase)
      assert_equal :tail_sampling, metadata.fetch(:destination)
      refute_includes metadata, :record_metadata
      assert_equal :tail_sampling_drop_callback, sampler.health.dig(:last_failure, :phase)
      assert_equal "RuntimeError", sampler.health.dig(:last_failure, :class)
    end

    def test_tail_sampling_resource_identity_is_self
      sampler = Julewire::TailSampling.new(destination: CapturingDestination.new, sample_rate: 1)

      assert_same sampler, sampler.resource_identity
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
      assert_equal :ok, plain_sampler.health.fetch(:status)
      assert_nil plain_sampler.health[:last_failure]
    end

    def test_tail_sampling_before_fork_drains_buffers_and_prepares_destination
      destination = BeforeForkDestination.new
      sampler = Julewire::TailSampling.new(destination: destination, sample_rate: 1)
      sampler.emit(build_record({ message: "pending", execution: { type: :job, id: "job-1" } }))

      assert_same sampler, sampler.before_fork!(timeout: 0.25)

      assert_equal 1, destination.records.length
      assert_equal 1, destination.before_fork_count
      assert_operator sampler.health.dig(:destination, :flushed), :>, 0
      assert_operator sampler.health.dig(:destination, :flushed), :<=, 0.25
      assert_operator destination.before_fork_timeout, :>, 0
      assert_operator destination.before_fork_timeout, :<=, 0.25
      assert_operator destination.before_fork_timeout, :<=, sampler.health.dig(:destination, :flushed)
      assert_equal 0, sampler.health.fetch(:buffered_executions)
    end

    def test_tail_sampling_before_fork_accepts_default_timeout
      destination = BeforeForkDestination.new
      sampler = Julewire::TailSampling.new(destination: destination, sample_rate: 1)

      assert_same sampler, sampler.before_fork!
      assert_equal 1, destination.before_fork_count
      assert_nil destination.before_fork_timeout
    end

    def test_tail_sampling_before_fork_preserves_destination_rejection
      destination = RejectingPreparationDestination.new
      sampler = Julewire::TailSampling.new(destination: destination, sample_rate: 1)

      assert_false sampler.before_fork!(timeout: 0.25)
      assert_equal 1, destination.before_fork_count
      assert_operator destination.before_fork_timeout, :>, 0
      assert_operator destination.before_fork_timeout, :<=, 0.25
    end

    def test_tail_sampling_before_fork_skips_destination_without_hook_and_keeps_buffer
      destination = CapturingDestination.new
      sampler = Julewire::TailSampling.new(destination: destination, sample_rate: 1)
      sampler.emit(build_record({ message: "pending", execution: { type: :job, id: "job-1" } }))

      assert_same sampler, sampler.before_fork!(timeout: 0.25)
      assert_equal 1, sampler.health.fetch(:buffered_executions)
      assert_empty destination.records
      assert_false sampler.health.dig(:destination, :flushed)
    end

    def test_tail_sampling_before_fork_rejects_invalid_timeout_before_flushing
      destination = BeforeForkDestination.new
      sampler = Julewire::TailSampling.new(destination: destination, sample_rate: 1)

      error = assert_raises(ArgumentError) { sampler.before_fork!(timeout: -1) }

      assert_equal "timeout must be nil or a non-negative finite Numeric", error.message
      assert_equal 0, destination.before_fork_count
      assert_false sampler.health.dig(:destination, :flushed)
    end

    def test_tail_sampling_after_fork_contains_destination_failures
      sampler = Julewire::TailSampling.new(destination: RaisingAfterForkDestination.new, sample_rate: 1)
      sampler.emit(build_record({ message: "pending", execution: { type: :job, id: "job-1" } }))

      assert_same sampler, sampler.after_fork!

      health = sampler.health

      assert_equal 0, health.fetch(:buffered_executions)
      assert_equal :degraded, health.fetch(:status)
      assert_equal "RuntimeError", health.dig(:last_failure, :class)
      assert_equal :after_fork, health.dig(:last_failure, :phase)
    end

    def test_tail_sampling_after_fork_propagates_unsafe_fork_errors
      sampler = Julewire::TailSampling.new(destination: UnsafeAfterForkDestination.new, sample_rate: 1)

      error = assert_raises(Julewire::Core::UnsafeForkError) { sampler.after_fork! }

      assert_equal "unsafe", error.message
    end

    def test_tail_sampling_before_fork_rejects_a_failed_drain
      sampler = Julewire::TailSampling.new(destination: RejectingBeforeForkDestination.new, sample_rate: 1)

      error = assert_raises(Julewire::Core::Error) { sampler.before_fork! }

      assert_equal "tail-sampling destination could not flush before fork", error.message
    end

    def test_tail_sampling_after_fork_waits_for_an_active_sampling_decision
      decision_started = Queue.new
      finish_decision = Queue.new
      sampler = Julewire::TailSampling.new(
        destination: CapturingDestination.new,
        decider: lambda { |*, **|
          decision_started << true
          finish_decision.pop
          true
        }
      )
      sampler.emit(build_record({ message: "pending", execution: { type: :job, id: "job-1" } }))
      emit_thread = safe_thread do
        sampler.emit(build_record({ kind: :summary, execution: { type: :job, id: "job-1" } }))
      end
      safe_queue_pop(decision_started)
      fork_thread = safe_thread { sampler.after_fork! }

      refute fork_thread.join(0.05), "after_fork completed during an active sampling decision"
      finish_decision << true

      assert_nil safe_thread_value(emit_thread)
      assert_same sampler, safe_thread_value(fork_thread)
      assert_equal 0, sampler.health.fetch(:buffered_executions)
    ensure
      finish_decision << true if defined?(finish_decision)
      cleanup_thread(emit_thread) if defined?(emit_thread)
      cleanup_thread(fork_thread) if defined?(fork_thread)
    end

    def test_tail_sampling_health_waits_for_an_active_sampling_decision
      decision_started = Queue.new
      finish_decision = Queue.new
      sampler = Julewire::TailSampling.new(
        destination: CapturingDestination.new,
        decider: lambda { |*, **|
          decision_started << true
          finish_decision.pop
          true
        }
      )
      sampler.emit(build_record({ message: "pending", execution: { type: :job, id: "job-1" } }))
      emit_thread = safe_thread do
        sampler.emit(build_record({ kind: :summary, execution: { type: :job, id: "job-1" } }))
      end
      safe_queue_pop(decision_started)
      health_thread = safe_thread { sampler.health }

      refute health_thread.join(0.05), "health observed a partially completed sampling decision"
      finish_decision << true

      assert_nil safe_thread_value(emit_thread)
      assert_equal 0, safe_thread_value(health_thread).fetch(:buffered_executions)
    ensure
      finish_decision << true if defined?(finish_decision)
      cleanup_thread(emit_thread) if defined?(emit_thread)
      cleanup_thread(health_thread) if defined?(health_thread)
    end

    def test_tail_sampling_flush_waits_for_an_active_sampling_decision
      decision_started = Queue.new
      finish_decision = Queue.new
      destination = CapturingDestination.new
      sampler = Julewire::TailSampling.new(
        destination: destination,
        decider: lambda { |*, **|
          decision_started << true
          finish_decision.pop
          true
        }
      )
      sampler.emit(build_record({ message: "pending", execution: { type: :job, id: "job-1" } }))
      emit_thread = safe_thread do
        sampler.emit(build_record({ kind: :summary, execution: { type: :job, id: "job-1" } }))
      end
      safe_queue_pop(decision_started)
      flush_thread = safe_thread { sampler.flush(timeout: 0.25) }

      refute flush_thread.join(0.05), "flush completed during an active sampling decision"
      finish_decision << true

      assert_nil safe_thread_value(emit_thread)
      assert_true safe_thread_value(flush_thread)
      assert_in_delta 0.25, destination.health.fetch(:flushed)
    ensure
      finish_decision << true if defined?(finish_decision)
      cleanup_thread(emit_thread) if defined?(emit_thread)
      cleanup_thread(flush_thread) if defined?(flush_thread)
    end

    def test_tail_sampling_health_reports_buffer_and_option_shape
      destination = CapturingDestination.new
      sampler = Julewire::TailSampling.new(
        destination: destination,
        max_executions: 3,
        max_records_per_execution: 2,
        sample_rate: 0.25,
        slow_ms: 12
      )

      sampler.emit(build_record({ message: "pending", execution: { type: :job, id: "job-1" } }))
      health = sampler.health

      assert_equal 1, health.fetch(:buffered_executions)
      assert_equal 3, health.fetch(:max_executions)
      assert_equal 2, health.fetch(:max_records_per_execution)
      assert_in_delta(0.25, health.fetch(:sample_rate))
      assert_equal 12, health.fetch(:slow_ms)
      assert_equal({ status: :ok, flushed: false, closed: false }, health.fetch(:destination))
    end

    def test_tail_sampling_records_destination_failures_and_health_failures
      failures = []
      sampler = Julewire::TailSampling.new(
        destination: RaisingDestination.new,
        sample_rate: 1,
        on_failure: ->(error, **metadata) { failures << [error, metadata] }
      )
      record = build_record({ event: "tail.emit", message: "lost", severity: :error })

      sampler.emit(record)

      emit_health = sampler.health
      emit_failure = failures.fetch(0).last

      assert_equal :tail_sampling, emit_failure.fetch(:destination)
      assert_equal :tail_sampling_destination, emit_failure.fetch(:phase)
      refute_includes emit_failure, :class
      assert_equal :tail_sampling, emit_health.dig(:last_failure, :destination)
      assert_equal :tail_sampling_destination, emit_health.dig(:last_failure, :phase)
      assert_equal "RuntimeError", emit_health.dig(:last_failure, :class)
      assert_equal "tail.emit", emit_health.dig(:last_failure, :record, :event)
      assert_equal :error, emit_health.dig(:last_failure, :record, :severity)

      assert_false sampler.flush(timeout: 1)

      health = sampler.health

      assert_equal :degraded, health.fetch(:status)
      assert_equal :tail_sampling_lifecycle, health.dig(:last_failure, :phase)
      assert_equal :flush, health.dig(:last_failure, :action)
      refute_includes health.fetch(:last_failure), :record
      assert_equal :tail_sampling_health, health.dig(:destination, :phase)
      assert_equal "RuntimeError", health.dig(:destination, :class)
      assert_equal :raising, health.dig(:destination, :destination)
      assert_instance_of RuntimeError, failures.first.first
      assert_equal :tail_sampling_destination, failures.first.last.fetch(:phase)
      assert_equal :tail_sampling, failures.fetch(1).last.fetch(:destination)
      assert_equal :flush, failures.fetch(1).last.fetch(:action)
      assert_instance_of RuntimeError, failures.fetch(1).first
      assert_equal "flush failed for 1", failures.fetch(1).first.message
      refute_includes failures.fetch(1).last, :class
    end

    def test_tail_sampling_records_close_lifecycle_failures
      failures = []
      sampler = Julewire::TailSampling.new(
        destination: RaisingDestination.new,
        sample_rate: 1,
        on_failure: ->(error, **metadata) { failures << [error.class, metadata] }
      )

      assert_false sampler.close(timeout: 2)

      health = sampler.health
      lifecycle_failure = failures.fetch(0).last

      assert_equal :degraded, health.fetch(:status)
      assert_equal :tail_sampling_lifecycle, health.dig(:last_failure, :phase)
      assert_equal :close, health.dig(:last_failure, :action)
      assert_equal :tail_sampling, lifecycle_failure.fetch(:destination)
      assert_equal :close, lifecycle_failure.fetch(:action)
      refute_includes lifecycle_failure, :class
    end

    def test_tail_sampling_contains_unexpected_emit_failures_with_default_phase
      failures = []
      sampler = Julewire::TailSampling.new(
        destination: CapturingDestination.new,
        on_failure: ->(error, **metadata) { failures << [error.class, metadata] },
        sample_rate: 1
      )
      record = RaisingKindRecord.new

      assert_nil sampler.emit(record)

      assert_equal RuntimeError, failures.fetch(0).first
      metadata = failures.fetch(0).last

      assert_equal :tail_sampling, metadata.fetch(:destination)
      assert_equal :tail_sampling, metadata.fetch(:phase)
      assert_equal "tail.pending", metadata.dig(:record_metadata, :event)
      assert_equal :warn, metadata.dig(:record_metadata, :severity)
    end

    def test_tail_sampling_records_failure_without_failure_callback
      sampler = Julewire::TailSampling.new(destination: RaisingDestination.new, sample_rate: 1)

      sampler.emit(build_record({ event: "tail.emit", message: "lost" }))

      assert_equal :tail_sampling_destination, sampler.health.dig(:last_failure, :phase)
    end

    def test_tail_sampling_contains_failure_callback_errors
      sampler = Julewire::TailSampling.new(
        destination: RaisingDestination.new,
        on_failure: ->(_error, **_metadata) { raise "callback failed" },
        sample_rate: 1
      )

      result = sampler.emit(build_record({ event: "tail.emit", message: "lost" }))

      assert_nil result
      assert_equal :tail_sampling_destination, sampler.health.dig(:last_failure, :phase)
    end

    def test_tail_sampling_accepts_hash_records_without_lineage
      destination = CapturingDestination.new
      sampler = Julewire::TailSampling.new(destination: destination, sample_rate: 1)

      sampler.emit({ kind: :point, execution: { id: "raw-1" }, message: "raw" })

      assert_true sampler.flush

      messages = destination.records.map { it.fetch(:message) }

      assert_equal ["raw"], messages
    end

    def test_tail_sampling_execution_key_prefers_lineage_root
      sampler, destination, keys = tail_sampling_key_probe
      execution = {
        type: "job",
        id: "job-1",
        root: { type: "request", id: "request-1" },
        depth: 1
      }

      sampler.emit(build_record({ message: "point", execution: execution }))
      sampler.emit(build_record({ kind: :summary, message: "done", execution: execution }))

      messages = destination.records.map { display_message(it) }

      assert_equal [%w[request request-1]], keys
      assert_equal %w[point done], messages
    end

    def test_tail_sampling_execution_key_accepts_hash_subclass_lineage_root
      sampler, destination, keys = tail_sampling_key_probe
      root = Class.new(Hash).new.merge!(type: "request", id: "request-1")
      execution = { type: "job", id: "job-1" }

      point = LineageBackedRecord.new(kind: :point, message: "point", execution: execution, root_reference: root)
      summary = LineageBackedRecord.new(kind: :summary, message: "done", execution: execution, root_reference: root)
      sampler.emit(point)
      sampler.emit(summary)

      assert_equal [%w[request request-1]], keys
      assert_equal [point, summary], destination.records
    end

    def test_tail_sampling_execution_key_falls_back_when_lineage_root_is_not_hash
      sampler, destination, keys = tail_sampling_key_probe
      execution = { type: "job", id: "job-1" }

      point = LineageBackedRecord.new(kind: :point, message: "point", execution: execution, root_reference: "bad")
      summary = LineageBackedRecord.new(kind: :summary, message: "done", execution: execution, root_reference: "bad")
      sampler.emit(point)
      sampler.emit(summary)

      assert_equal [%w[job job-1]], keys
      assert_equal [point, summary], destination.records
    end

    def test_tail_sampling_execution_key_falls_back_to_hash_execution_and_freezes_key
      sampler, destination, keys = tail_sampling_key_probe

      sampler.emit({ kind: :point, execution: { type: "job", id: "raw-1" }, message: "raw" })
      sampler.emit({ kind: :summary, execution: { type: "job", id: "raw-1" }, message: "done" })

      messages = destination.records.map { it.fetch(:message) }

      assert_equal [%w[job raw-1]], keys
      assert_predicate keys.fetch(0), :frozen?
      assert_equal %w[raw done], messages
    end

    def test_tail_sampling_execution_key_accepts_index_only_records
      sampler, destination, keys = tail_sampling_key_probe
      execution = { type: "job", id: "job-1" }

      point = IndexOnlyRecord.new(kind: :point, execution: execution, message: "point")
      summary = IndexOnlyRecord.new(kind: :summary, execution: execution, message: "done")
      sampler.emit(point)
      sampler.emit(summary)

      assert_equal [%w[job job-1]], keys
      assert_equal [point, summary], destination.records
    end

    def test_tail_sampling_error_check_accepts_index_only_records
      destination = CapturingDestination.new
      sampler = Julewire::TailSampling.new(destination: destination, sample_rate: 0)
      execution = { type: "job", id: "job-1" }
      point = IndexOnlyRecord.new(kind: :point, execution: execution, message: "point", severity: :info)
      summary = IndexOnlyRecord.new(kind: :summary, execution: execution, message: "done", severity: :error)

      sampler.emit(point)
      sampler.emit(summary)

      assert_equal [point, summary], destination.records
    end

    def test_tail_sampling_treats_broken_lineage_records_as_immediate
      destination = CapturingDestination.new
      sampler = Julewire::TailSampling.new(destination: destination, sample_rate: 0)
      record = BrokenLineageRecord.new

      sampler.emit(record)

      assert_equal [record], destination.records
      assert_equal 1, sampler.health.dig(:counts, :immediate)
    end

    def test_tail_sampling_validates_destination_and_sampling_options
      assert_raises_message(ArgumentError, /destination must respond to #name/) do
        Julewire::TailSampling.new(destination: Object.new)
      end

      assert_raises_message(ArgumentError, /unknown tail_sampling options: extra/) do
        Julewire::TailSampling.new(destination: CapturingDestination.new, extra: true)
      end

      assert_raises_message(ArgumentError, /rate must be a finite Numeric between 0 and 1/) do
        Julewire::TailSampling.new(destination: CapturingDestination.new, sample_rate: 2)
      end

      assert_raises_message(ArgumentError, /slow_ms must be a non-negative Numeric/) do
        Julewire::TailSampling.new(destination: CapturingDestination.new, slow_ms: Object.new)
      end
      assert_raises_message(ArgumentError, /slow_ms must be a non-negative Numeric/) do
        Julewire::TailSampling.new(destination: CapturingDestination.new, slow_ms: Float::INFINITY)
      end
      assert_raises_message(ArgumentError, /slow_ms must be a non-negative Numeric/) do
        Julewire::TailSampling.new(destination: CapturingDestination.new, slow_ms: Float::NAN)
      end

      assert_raises_message(ArgumentError, /slow_ms must be non-negative/) do
        Julewire::TailSampling.new(destination: CapturingDestination.new, slow_ms: -1)
      end
    end

    def test_tail_sampling_validates_name_and_capacity_options
      assert_raises_message(ArgumentError, /destination name must be a String or Symbol/) do
        Julewire::TailSampling.new(destination: CapturingDestination.new, name: nil)
      end

      assert_raises_message(ArgumentError, /destination name must be a String or Symbol/) do
        Julewire::TailSampling.new(destination: CapturingDestination.new, name: Object.new)
      end

      assert_raises_message(ArgumentError, /destination name must not be empty/) do
        Julewire::TailSampling.new(destination: CapturingDestination.new, name: "")
      end

      assert_raises_message(ArgumentError, /max_executions must be a positive Integer/) do
        Julewire::TailSampling.new(destination: CapturingDestination.new, max_executions: 0)
      end

      assert_raises_message(ArgumentError, /max_records_per_execution must be a positive Integer/) do
        Julewire::TailSampling.new(destination: CapturingDestination.new, max_records_per_execution: 0)
      end
    end

    def test_tail_sampling_validates_callback_options
      assert_raises_message(ArgumentError, /decider must respond to #call/) do
        Julewire::TailSampling.new(destination: CapturingDestination.new, decider: Object.new)
      end

      assert_raises_message(ArgumentError, /on_drop must respond to #call/) do
        Julewire::TailSampling.new(destination: CapturingDestination.new, on_drop: Object.new)
      end

      assert_raises_message(ArgumentError, /on_failure must respond to #call/) do
        Julewire::TailSampling.new(destination: CapturingDestination.new, on_failure: Object.new)
      end
    end

    private

    def tail_sampling_key_probe
      keys = []
      destination = CapturingDestination.new
      sampler = Julewire::TailSampling.new(
        destination: destination,
        decider: ->(_record, key:) { keys << key },
        sample_rate: 0
      )

      [sampler, destination, keys]
    end

    def display_message(record)
      Julewire::Core::Records::DisplayMessage.call(record)
    end
  end
end
