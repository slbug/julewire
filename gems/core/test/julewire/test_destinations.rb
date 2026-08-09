# frozen_string_literal: true

require "test_helper"
require "json"
require "stringio"

module Julewire
  class TestDestinations < Minitest::Test
    cover Julewire::Core::Destinations
    cover Julewire::Core::Destinations::Destination
    cover Julewire::Core::Destinations::Definition
    cover Julewire::Core::Destinations::Registry
    cover Julewire::Core::Destinations::Sink
    cover "Julewire::Core::Destinations::Definition#build"
    cover "Julewire::Core::Destinations::Destination#after_fork!"
    cover "Julewire::Core::Destinations::Destination#initialize"
    cover "Julewire::Core::Destinations::Destination#call_output_lifecycle_safely"
    cover "Julewire::Core::Destinations::Destination#record_loss"
    cover "Julewire::Core::Destinations::Sink.wrap"
    cover "Julewire::Core::Runtime#degraded_health?"

    class MutatingFormatter
      def call(record)
        record.fetch(:payload)[:mutated] = true
        { line: "mutated" }
      end
    end

    class ObservingFormatter
      def call(record)
        { line: "mutated=#{record.fetch(:payload).key?(:mutated)}" }
      end
    end

    class CapturingDestination
      attr_reader :name, :records

      def initialize(name)
        @name = name
        @records = []
      end

      def emit(record)
        @records << record
      end

      def flush(timeout: nil); end

      def close(timeout: nil); end

      def health
        { status: :ok, records: records.length }
      end
    end

    class CustomDestination
      attr_reader :name, :records

      def initialize(name)
        @name = name
        @records = []
      end

      def emit(record)
        records << record
      end

      def flush(timeout: nil)
        @flushed_timeout = timeout
      end

      def close(timeout: nil); end

      def health
        {
          status: :ok,
          type: "custom",
          flushed_timeout: @flushed_timeout,
          records: records.length
        }
      end
    end

    class StatuslessDestination < CustomDestination
      def health
        { type: "custom", records: records.length }
      end
    end

    class CopyableDestination < CustomDestination
      attr_reader :copied_from

      def initialize(name, copied_from: nil)
        super(name)
        @copied_from = copied_from
      end

      def copy
        self.class.new(name, copied_from: self)
      end
    end

    class ForkFailingDestination < CustomDestination
      def after_fork!
        raise "destination fork failed"
      end
    end

    class HealthFailingDestination < CustomDestination
      def health
        raise "health failed"
      end
    end

    class RaisingDestination
      def name
        :raising
      end

      def emit(_record)
        raise "destination failed"
      end

      def flush(timeout: nil); end

      def close(timeout: nil); end

      def health
        { status: :ok }
      end
    end

    class MetadataRecordish
      def initialize(values)
        @values = values
      end

      def key?(key) = @values.key?(key)

      def [](key) = @values[key]
    end

    class FlakyFlushOutput
      def initialize(*results)
        @results = results
      end

      def write(_value); end

      def flush
        @results.shift
      end
    end

    class ReentrantFlushOutput
      attr_writer :during_flush

      def write(_value) = false # rubocop:disable Naming/PredicateMethod -- Output protocol uses truthy results.

      def flush # rubocop:disable Naming/PredicateMethod -- Output protocol uses truthy results.
        @during_flush.call
        true
      end
    end

    class ForkFailingOutput
      def write(_value); end

      def after_fork!
        raise "output fork failed"
      end
    end

    class UnsafeForkOutput
      def write(_value); end

      def after_fork!
        raise Julewire::Core::UnsafeForkError, "unsafe output"
      end
    end

    class FlushFailingOutput
      def write(_value); end

      def flush
        raise "flush failed"
      end
    end

    class TimeoutRecordingOutput
      attr_reader :close_timeout

      def write(_value); end

      def close(timeout: nil)
        @close_timeout = timeout
      end
    end

    class WriteFailingOutput
      def write(_value)
        raise "write failed"
      end
    end

    class RejectingOutput
      def write(_value) # rubocop:disable Naming/PredicateMethod
        false
      end
    end

    class EqualOutput < StringIO
      def hash = 1

      def eql?(other) = other.is_a?(EqualOutput)
    end

    class DestinationList
      def initialize(destinations)
        @destinations = destinations
      end

      def build(*)
        @destinations
      end

      def copy
        self.class.new(@destinations)
      end
    end

    def test_default_named_destination_uses_its_formatter_and_output
      output = StringIO.new

      Julewire.configure do |config|
        configure_destination(
          config,
          formatter: Julewire::Core::TestHelpers::TestLineFormatter.new("default"),
          output: output
        )
      end

      Julewire.emit(message: "hello")

      assert_equal({ "line" => "default:hello" }, JSON.parse(output.string))
      assert_equal [:default], Julewire.health.fetch(:pipeline).fetch(:destinations).keys
    end

    def test_explicit_destinations_do_not_build_implicit_default_destination
      cloud_output = StringIO.new
      file_output = StringIO.new

      Julewire.configure do |config|
        config.destinations.use(
          :cloud_json,
          formatter: Julewire::Core::TestHelpers::TestLineFormatter.new("cloud"),
          output: cloud_output
        )
        config.destinations.use(
          :debug_file,
          formatter: Julewire::Core::TestHelpers::TestLineFormatter.new("debug"),
          output: file_output
        )
      end

      Julewire.emit(message: "work")

      assert_equal({ "line" => "cloud:work" }, JSON.parse(cloud_output.string))
      assert_equal({ "line" => "debug:work" }, JSON.parse(file_output.string))
      assert_equal %i[cloud_json debug_file], Julewire.health.fetch(:pipeline).fetch(:destinations).keys
    end

    def test_destination_processors_mutate_only_that_destination
      default_output = StringIO.new
      audit_output = StringIO.new
      audit_processor = lambda do |draft|
        draft[:message] = "audit:#{draft.fetch(:message)}"
      end

      Julewire.configure do |config|
        config.destinations.use(
          :default,
          formatter: Julewire::Core::TestHelpers::TestLineFormatter.new("default"),
          output: default_output
        )
        config.destinations.use(
          :audit,
          formatter: Julewire::Core::TestHelpers::TestLineFormatter.new("audit"),
          output: audit_output,
          processors: [audit_processor]
        )
      end

      Julewire.emit(message: "work")

      assert_equal({ "line" => "default:work" }, JSON.parse(default_output.string))
      assert_equal({ "line" => "audit:audit:work" }, JSON.parse(audit_output.string))
    end

    def test_destination_processors_drop_only_that_destination
      default_output = StringIO.new
      audit_output = StringIO.new

      Julewire.configure do |config|
        config.destinations.use(
          :default,
          formatter: Julewire::Core::TestHelpers::TestLineFormatter.new("default"),
          output: default_output
        )
        config.destinations.use(
          :audit,
          formatter: Julewire::Core::TestHelpers::TestLineFormatter.new("audit"),
          output: audit_output,
          processors: ->(_draft) { :drop }
        )
      end

      Julewire.emit(message: "work")

      assert_equal({ "line" => "default:work" }, JSON.parse(default_output.string))
      assert_empty audit_output.string
      assert_equal 1, Julewire.health.dig(:pipeline, :destinations, :audit, :counts, :processor_dropped)
    end

    def test_destination_processor_failure_emits_error_record_to_that_destination
      default_output = StringIO.new
      audit_output = StringIO.new

      Julewire.configure do |config|
        config.destinations.use(
          :default,
          formatter: Julewire::Core::TestHelpers::TestLineFormatter.new("default"),
          output: default_output
        )
        config.destinations.use(
          :audit,
          formatter: Julewire::Core::TestHelpers::TestLineFormatter.new("audit"),
          output: audit_output,
          processors: ->(_draft) { raise "audit failed" }
        )
      end

      Julewire.emit(message: "work")

      assert_equal({ "line" => "default:work" }, JSON.parse(default_output.string))
      assert_equal({ "line" => "audit:Julewire processor failed" }, JSON.parse(audit_output.string))
      assert_equal :degraded, Julewire.health.dig(:pipeline, :destinations, :audit, :status)
      assert_equal 1, Julewire.health.dig(:pipeline, :destinations, :audit, :counts, :processor_error)
      assert_equal :destination_processor,
                   Julewire.health.dig(:pipeline, :destinations, :audit, :last_failure, :phase)
    end

    def test_destination_formatters_receive_immutable_records
      mutated_output = StringIO.new
      observed_output = StringIO.new

      Julewire.configure do |config|
        config.destinations.use(:mutating, formatter: MutatingFormatter.new, output: mutated_output)
        config.destinations.use(:observing, formatter: ObservingFormatter.new, output: observed_output)
      end

      Julewire.emit(payload: {})

      assert_empty mutated_output.string
      assert_equal({ "line" => "mutated=false" }, JSON.parse(observed_output.string))
      assert_mutating_destination_loss
    end

    def assert_mutating_destination_loss
      health = Julewire.health.fetch(:pipeline).fetch(:destinations).fetch(:mutating)

      assert_equal 1, health.dig(:counts, :formatter_error)
      assert_equal :degraded, health.fetch(:status)
      assert_equal :formatter_error, health.dig(:last_loss, :reason)
    end

    def test_custom_destination_failure_does_not_stop_later_destinations
      failures = Queue.new
      captured = CapturingDestination.new(:captured)
      pipeline = custom_destination_pipeline(
        destinations: [RaisingDestination.new, captured],
        on_failure: ->(error, metadata) { failures << [error, metadata] }
      )

      pipeline.emit(message: "work")

      error, metadata = safe_queue_pop(failures)

      assert_equal "destination failed", error.message
      assert_equal :destination, metadata.fetch(:phase)
      assert_equal :raising, metadata.fetch(:destination)
      assert_equal "log", metadata.dig(:record_metadata, :event)
      assert_equal 1, captured.records.length
    end

    def test_custom_destination_after_fork_failures_are_contained
      failures = Queue.new
      pipeline = custom_destination_pipeline(
        destinations: [ForkFailingDestination.new(:forking)],
        on_failure: ->(error, metadata) { failures << [error, metadata] }
      )

      assert_same pipeline, pipeline.after_fork!

      error, metadata = safe_queue_pop(failures)

      assert_equal "destination fork failed", error.message
      assert_equal :after_fork, metadata.fetch(:action)
      assert_equal :forking, metadata.fetch(:destination)
      assert_equal :destination_lifecycle, metadata.fetch(:phase)
    end

    def test_custom_destinations_without_after_fork_are_skipped
      failures = Queue.new
      destination = CustomDestination.new(:transport)
      pipeline = custom_destination_pipeline(
        destinations: [destination],
        on_failure: ->(error, metadata) { failures << [error, metadata] }
      )

      assert_same pipeline, pipeline.after_fork!

      assert_empty nonblocking_queue_values(failures)
    end

    def test_registry_accepts_custom_destination_objects
      destination = CustomDestination.new(:transport)

      Julewire.configure do |config|
        config.destinations.add(destination)
      end

      Julewire.emit(message: "custom")
      Julewire.flush(timeout: 0.1)

      assert_equal 1, destination.records.length
      assert_equal "custom", destination.records.first.fetch(:message)
      assert_equal 1, Julewire.health.dig(:pipeline, :destinations, :transport, :records)
      flushed_timeout = Julewire.health.dig(:pipeline, :destinations, :transport, :flushed_timeout)

      assert_operator flushed_timeout, :>, 0
      assert_in_delta 0.1, flushed_timeout, 0.01
    end

    def test_custom_destination_nil_lifecycle_result_is_successful
      destination = CapturingDestination.new(:transport)

      Julewire.configure do |config|
        config.destinations.add(destination)
      end

      assert_true Julewire.flush
      assert_true Julewire.close
    end

    def test_custom_destination_health_without_status_does_not_degrade_runtime
      destination = StatuslessDestination.new(:transport)

      Julewire.configure do |config|
        config.destinations.add(destination)
      end

      Julewire.emit(message: "custom")
      health = Julewire.health

      assert_equal :ok, health.fetch(:status)
      assert_equal 1, health.dig(:pipeline, :destinations, :transport, :records)
      refute_includes health.dig(:pipeline, :destinations, :transport), :status
    end

    def test_destination_health_failure_preserves_other_destination_health
      healthy = CustomDestination.new(:healthy)
      failing = HealthFailingDestination.new(:failing)

      Julewire.configure do |config|
        config.destinations.add(healthy)
        config.destinations.add(failing)
      end

      destinations = Julewire.health.fetch(:pipeline).fetch(:destinations)

      assert_equal :ok, destinations.fetch(:healthy).fetch(:status)
      assert_equal :unknown, destinations.fetch(:failing).fetch(:status)
      assert_equal "RuntimeError", destinations.dig(:failing, :last_failure, :class)
      assert_equal :destination_health, destinations.dig(:failing, :last_failure, :phase)
    end

    def custom_destination_pipeline(destinations:, on_drop: nil, on_failure: nil)
      configuration = Core::Configuration.new
      configuration.on_drop = on_drop
      configuration.on_failure = on_failure
      configuration.instance_variable_set(:@destinations, DestinationList.new(destinations))
      Core::Processing::Pipeline.new(configuration: configuration.snapshot)
    end

    def test_destination_formatter_gets_immutable_record
      output = StringIO.new

      Julewire.configure do |config|
        configure_destination(config, formatter: MutatingFormatter.new, output: output)
      end

      Julewire.emit(payload: {})

      assert_empty output.string
      assert_equal 1, Julewire.health.dig(:pipeline, :destinations, :default, :counts, :formatter_error)
    end

    def test_direct_destination_lifecycle_rejects_invalid_timeouts
      destination = build_destination(output: StringIO.new)

      flush_error = assert_raises(ArgumentError) { destination.flush(timeout: -1) }
      close_error = assert_raises(ArgumentError) { destination.close(timeout: "slow") }

      assert_equal "timeout must be nil or a non-negative finite Numeric", flush_error.message
      assert_equal "timeout must be nil or a non-negative finite Numeric", close_error.message
    end

    def test_direct_destination_flush_without_timeout_uses_default
      destination = build_destination(output: StringIO.new)

      assert_true destination.flush
    end

    def test_direct_destination_after_fork_returns_self_and_reports_failures
      destination = build_destination(output: ForkFailingOutput.new)

      assert_same destination, destination.after_fork!

      health = destination.health

      assert_equal :degraded, health.fetch(:status)
      assert_equal :after_fork, health.dig(:last_failure, :action)
      assert_equal :output_lifecycle, health.dig(:last_failure, :phase)
      assert_equal "Julewire::TestDestinations::ForkFailingOutput", health.dig(:last_failure, :output_class)
      assert_equal "RuntimeError", health.dig(:last_failure, :class)
    end

    def test_direct_destination_after_fork_success_returns_self
      destination = build_destination(output: StringIO.new)

      assert_same destination, destination.after_fork!
    end

    def test_direct_destination_after_fork_propagates_unsafe_fork_errors
      destination = build_destination(output: UnsafeForkOutput.new)

      error = assert_raises(Julewire::Core::UnsafeForkError) { destination.after_fork! }

      assert_equal "unsafe output", error.message
    end

    def test_direct_destination_after_fork_resets_health
      destination = build_destination(output: RejectingOutput.new)

      destination.emit(build_record({ message: "bad" }))

      assert_equal :degraded, destination.health.fetch(:status)

      assert_same destination, destination.after_fork!

      assert_equal :ok, destination.health.fetch(:status)
      assert_equal 0, destination.health.dig(:counts, :output_rejected)
    end

    def test_direct_destination_lifecycle_failure_reports_output_class
      destination = build_destination(output: FlushFailingOutput.new)

      assert_false destination.flush

      health = destination.health

      assert_equal :degraded, health.fetch(:status)
      assert_equal :flush, health.dig(:last_failure, :action)
      assert_equal "Julewire::TestDestinations::FlushFailingOutput", health.dig(:last_failure, :output_class)
    end

    def test_direct_destination_close_forwards_timeout
      output = TimeoutRecordingOutput.new
      destination = build_destination(output: output, close_output: true)

      assert_true destination.close(timeout: 0.25)

      assert_in_delta 0.25, output.close_timeout, 0.001
    end

    def test_direct_destination_resource_identity_uses_output_identity
      output = StringIO.new
      destination = build_destination(output: output)

      assert_same output, destination.resource_identity
    end

    def test_direct_destination_write_failure_metadata_uses_compact_record_shape
      failures = Queue.new
      destination = build_destination(
        output: WriteFailingOutput.new,
        on_failure: ->(error, metadata) { failures << [error, metadata] }
      )
      record = build_record({ event: "write.failed", message: "bad" })

      destination.emit(record)

      error, metadata = safe_queue_pop(failures)
      health = destination.health

      assert_equal "write failed", error.message
      assert_equal "write.failed", metadata.dig(:record_metadata, :event)
      assert_equal "write.failed", health.dig(:last_failure, :record, :event)
    end

    def test_direct_destination_callback_failure_metadata_includes_destination
      destination = build_destination(
        output: WriteFailingOutput.new,
        on_failure: ->(_error, _metadata) { raise "callback failed" }
      )

      destination.emit(build_record({ message: "bad" }))

      callback_failure = destination.health.fetch(:last_callback_failure)

      assert_equal :default, callback_failure.fetch(:destination)
      assert_equal :output, callback_failure.fetch(:phase)
    end

    def test_direct_destination_processor_drop_skips_write
      output = StringIO.new
      destination = build_destination_with_processors(
        output: output,
        processors: ->(_draft) { :drop },
        formatter: ->(_record) { raise "formatter should not run" }
      )

      assert_nil destination.emit(build_record({ message: "drop" }))

      assert_empty output.string
      health = destination.health

      assert_equal 1, health.dig(:counts, :processor_dropped)
      assert_equal 0, health.dig(:counts, :formatter_error)
      assert_nil health.fetch(:last_failure)
    end

    def test_direct_destination_false_flush_keeps_current_degradation
      destination = build_destination(
        formatter: ->(_record) {},
        output: FlakyFlushOutput.new(false)
      )

      destination.emit(build_record({ message: "bad" }))

      assert_equal :degraded, destination.health.fetch(:status)
      assert_false destination.flush
      assert_equal :degraded, destination.health.fetch(:status)
    end

    def test_direct_destination_successful_flush_clears_current_degradation
      destination = build_destination(
        formatter: ->(_record) {},
        output: FlakyFlushOutput.new(true)
      )

      destination.emit(build_record({ message: "bad" }))

      assert_equal :degraded, destination.health.fetch(:status)
      assert_true destination.flush
      assert_equal :ok, destination.health.fetch(:status)
    end

    def test_direct_destination_flush_does_not_clear_newer_reentrant_degradation
      output = ReentrantFlushOutput.new
      destination = build_destination(output: output)
      output.during_flush = lambda do
        destination.emit(build_record({ event: "newer.failure", message: "newer" }))
      end

      destination.emit(build_record({ event: "initial.failure", message: "initial" }))

      assert_true destination.flush
      health = destination.health

      assert_equal :degraded, health.fetch(:status)
      assert_equal "newer.failure", health.dig(:last_loss, :event)
    end

    def test_direct_destination_close_success_does_not_clear_current_degradation
      destination = build_destination(
        formatter: ->(_record) {},
        output: FlakyFlushOutput.new(true)
      )

      destination.emit(build_record({ message: "bad" }))

      assert_equal :degraded, destination.health.fetch(:status)
      assert_true destination.close
      assert_equal :degraded, destination.health.fetch(:status)
    end

    def test_direct_destination_rejected_write_does_not_clear_existing_degradation
      destination = build_destination(output: RejectingOutput.new)
      record = build_record({ event: "rejected.event", message: "rejected", severity: :warn })

      destination.emit(record)

      marker = destination.health.fetch(:last_loss)

      assert_equal :degraded, destination.health.fetch(:status)

      destination.emit(record)

      health = destination.health

      assert_equal :degraded, health.fetch(:status)
      assert_equal :output_rejected, health.dig(:last_loss, :reason)
      assert_equal "rejected.event", health.dig(:last_loss, :event)
      assert_equal :warn, health.dig(:last_loss, :severity)
      assert_instance_of Time, health.dig(:last_loss, :at)
      assert_predicate health.dig(:last_loss, :at), :utc?
      refute_same marker, health.fetch(:last_loss)
    end

    def test_direct_destination_record_loss_tolerates_compacted_record_metadata
      destination = build_destination(
        formatter: ->(record) { record },
        output: RejectingOutput.new
      )
      record = MetadataRecordish.new(source: "test")

      destination.emit(record)

      last_loss = destination.health.fetch(:last_loss)

      assert_equal :output_rejected, last_loss.fetch(:reason)
      assert_equal "test", last_loss.fetch(:source)
      refute_includes last_loss, :event
      refute_includes last_loss, :severity
    end

    def build_destination_with_processors(output:, processors:, formatter: Julewire::Core::Records::Formatter.new)
      Julewire::Core::Destinations::Destination.new(
        name: :default,
        close_output: false,
        encoder: Julewire::Core::Serialization::JsonEncoder.new,
        formatter: formatter,
        max_record_bytes: Julewire::Core::DEFAULT_MAX_RECORD_BYTES,
        on_drop: nil,
        on_failure: nil,
        output: output,
        processors: processors
      )
    end
  end

  class TestDestinationDefinitionValidation < Minitest::Test
    cover Julewire::Core::Destinations
    cover Julewire::Core::Destinations::Destination
    cover Julewire::Core::Destinations::Definition
    cover Julewire::Core::Destinations::Registry
    cover Julewire::Core::Destinations::Sink
    cover "Julewire::Core::Destinations::Destination#initialize"
    cover "Julewire::Core::Destinations::Definition#build"
    cover "Julewire::Core::Destinations::Sink.wrap"

    def test_destination_requires_output
      error = assert_raises(ArgumentError) do
        Julewire.configure do |config|
          config.destinations.use(
            :cloud_json,
            formatter: Julewire::Core::TestHelpers::TestLineFormatter.new("cloud")
          )
        end
      end

      assert_equal "destination :cloud_json output is required", error.message
    end

    def test_destination_definition_normalizes_kind_and_default_name
      definition = Julewire::Core::Destinations::Definition.new("direct", output: StringIO.new)

      assert_equal :direct, definition.kind
      assert_equal :direct, definition.name
    end

    def test_destination_definition_normalizes_explicit_name
      definition = Julewire::Core::Destinations::Definition.new(:direct, name: "explicit", output: StringIO.new)

      assert_equal :explicit, definition.name
    end

    def test_direct_destination_normalizes_name
      destination = build_destination(name: "direct", output: StringIO.new)

      assert_equal :direct, destination.name
    end

    def test_destination_rejects_nil_output_when_constructed_directly
      error = assert_raises(ArgumentError) do
        build_destination(output: nil, name: :direct)
      end

      assert_equal "destination :direct output is required", error.message
    end

    def test_direct_destination_validates_callable_option_names
      formatter_error = assert_raises(ArgumentError) do
        build_destination(formatter: Object.new, output: StringIO.new)
      end
      encoder_error = assert_raises(ArgumentError) do
        build_destination(encoder: Object.new, output: StringIO.new)
      end
      on_drop_error = assert_raises(ArgumentError) do
        build_destination(on_drop: Object.new, output: StringIO.new)
      end
      on_failure_error = assert_raises(ArgumentError) do
        build_destination(on_failure: Object.new, output: StringIO.new)
      end

      assert_equal "formatter must respond to #call", formatter_error.message
      assert_equal "encoder must respond to #call", encoder_error.message
      assert_equal "on_drop must respond to #call", on_drop_error.message
      assert_equal "on_failure must respond to #call", on_failure_error.message
    end

    def test_direct_destination_validates_record_size_limit_name
      error = assert_raises(ArgumentError) do
        build_destination(output: StringIO.new, max_record_bytes: 0)
      end

      assert_equal "max_record_bytes must be nil or a positive Integer", error.message
    end

    def test_destinations_reject_shared_raw_output
      output = StringIO.new

      error = assert_raises(ArgumentError) do
        Julewire.configure do |config|
          config.destinations.use(:one, output: output)
          config.destinations.use(:two, output: output)
        end
      end

      assert_equal(
        "destination :two shares output with destination :one; use a transport adapter for shared sinks",
        error.message
      )
    end

    def test_destination_rejects_unknown_options
      error = assert_raises(ArgumentError) do
        Julewire.configure do |config|
          configure_destination(config, output: StringIO.new)
          config.destinations.use(:debug, transport: true)
        end
      end

      assert_equal "unknown destination options: transport", error.message
    end

    def test_destination_definition_requires_shared_pipeline_defaults
      definition = Julewire::Core::Destinations::Definition.new(:direct, output: StringIO.new)

      error = assert_raises(ArgumentError) { definition.build(defaults: {}) }

      assert_equal "destination default encoder is required", error.message
    end

    def test_destination_definition_requires_formatter_default_after_encoder_default
      definition = Julewire::Core::Destinations::Definition.new(:direct, output: StringIO.new)

      error = assert_raises(ArgumentError) do
        definition.build(defaults: { encoder: Julewire::Core::Serialization::JsonEncoder.new })
      end

      assert_equal "destination default formatter is required", error.message
    end

    def test_destination_definition_requires_output_after_defaults_are_available
      definition = Julewire::Core::Destinations::Definition.new(:direct)

      error = assert_raises(ArgumentError) { definition.build(defaults: destination_defaults) }

      assert_equal "destination :direct output is required", error.message
    end

    def test_destination_definition_does_not_reserve_nil_output_identity
      definition = Julewire::Core::Destinations::Definition.new(:direct)
      output_identities = {}.compare_by_identity

      error = assert_raises(ArgumentError) do
        definition.build(defaults: destination_defaults, output_identities: output_identities)
      end

      assert_equal "destination :direct output is required", error.message
      assert_empty output_identities
    end

    def test_destination_registry_tracks_shared_outputs_by_identity
      registry = Julewire::Core::Destinations::Registry.new
      first = TestDestinations::EqualOutput.new
      second = TestDestinations::EqualOutput.new

      registry.use(:direct, name: :first, output: first)
      registry.use(:direct, name: :second, output: second)

      destinations = registry.build(defaults: destination_defaults)

      assert_predicate destinations, :frozen?
      assert_equal %i[first second], destinations.map(&:name)
      refute_same first, second
      assert_eql first, second
    end

    def test_destination_definition_uses_inherited_defaults
      output = StringIO.new
      formatter = Julewire::Core::TestHelpers::TestLineFormatter.new("direct")
      definition = Julewire::Core::Destinations::Definition.new(:direct, output: output)
      destination = definition.build(defaults: destination_defaults(formatter: formatter))

      destination.emit(build_record({ message: "hello" }))
      destination.close

      assert_equal({ "line" => "direct:hello" }, JSON.parse(output.string))
      refute_predicate output, :closed?
    end

    def test_destination_definition_forwards_close_output
      output = StringIO.new
      definition = Julewire::Core::Destinations::Definition.new(:direct, output: output, close_output: true)
      destination = definition.build(defaults: destination_defaults)

      assert_true destination.close
      assert_predicate output, :closed?
    end

    def test_destination_definition_uses_default_callbacks
      drops = Queue.new
      failures = Queue.new
      drop_definition = Julewire::Core::Destinations::Definition.new(:direct, output: TestDestinations::RejectingOutput.new)
      failure_definition = Julewire::Core::Destinations::Definition.new(
        :direct,
        formatter: ->(_record) { raise "format failed" },
        output: StringIO.new
      )
      defaults = destination_defaults(
        **queue_callbacks(drops: drops, failures: failures)
      )

      drop_definition.build(defaults: defaults).emit(build_record({ message: "drop" }))
      failure_definition.build(defaults: defaults).emit(build_record({ message: "fail" }))

      drop_reason, drop_metadata = safe_queue_pop(drops)
      failure_error, failure_metadata = safe_queue_pop(failures)

      assert_equal :output_rejected, drop_reason
      assert_equal :destination, drop_metadata.fetch(:phase)
      assert_equal "format failed", failure_error.message
      assert_equal :formatter, failure_metadata.fetch(:phase)
    end

    def test_destination_definition_does_not_require_callback_defaults
      output = StringIO.new
      definition = Julewire::Core::Destinations::Definition.new(:direct, output: output)
      destination = definition.build(
        defaults: {
          encoder: Julewire::Core::Serialization::JsonEncoder.new,
          formatter: Julewire::Core::TestHelpers::TestLineFormatter.new("direct")
        }
      )

      destination.emit(build_record({ message: "hello" }))

      assert_equal({ "line" => "direct:hello" }, JSON.parse(output.string))
    end

    def test_destination_definition_uses_default_record_size_limit
      output = StringIO.new
      definition = Julewire::Core::Destinations::Definition.new(:direct, output: output)
      destination = definition.build(
        defaults: {
          encoder: ->(_formatted) { "x" * (Julewire::Core::DEFAULT_MAX_RECORD_BYTES + 1) },
          formatter: ->(_record) { {} }
        }
      )

      destination.emit(build_record({ message: "too large" }))

      assert_empty output.string
      assert_equal 1, destination.health.dig(:counts, :record_too_large)
    end

    def test_destination_definition_copy_preserves_options_without_sharing_option_hash
      definition = Julewire::Core::Destinations::Definition.new(
        :direct,
        output: StringIO.new,
        name: :copy_source,
        processors: []
      )
      copy = definition.copy

      assert_equal definition.kind, copy.kind
      assert_equal definition.name, copy.name
      refute_same definition, copy
    end

    def test_destination_names_are_unique
      error = assert_raises(ArgumentError) do
        Julewire.configure do |config|
          configure_destination(config, output: StringIO.new)
          config.destinations.use(:cloud_json)
          config.destinations.use(:cloud_json)
        end
      end

      assert_equal "destination :cloud_json is already configured", error.message
    end

    def test_custom_destination_names_must_be_unique
      error = assert_raises(ArgumentError) do
        Julewire.configure do |config|
          config.destinations.add(TestDestinations::CustomDestination.new(:transport))
          config.destinations.add(TestDestinations::CustomDestination.new(:transport))
        end
      end

      assert_equal "destination :transport is already configured", error.message
    end

    def test_destination_registry_empty_tracks_configured_definitions
      registry = Julewire::Core::Destinations::Registry.new

      assert_predicate registry, :empty?
      registry.use(:default, output: StringIO.new)

      refute_predicate registry, :empty?
    end

    def test_destination_registry_freeze_returns_registry_and_blocks_mutation
      registry = Julewire::Core::Destinations::Registry.new

      assert_same registry, registry.freeze
      assert_predicate registry, :frozen?
      assert_raises(FrozenError) { registry.use(:default, output: StringIO.new) }
    end

    def test_destination_registry_mutators_return_registry
      registry = Julewire::Core::Destinations::Registry.new

      assert_same registry, registry.use(:default, output: StringIO.new)
      assert_same registry, registry.add(TestDestinations::CustomDestination.new(:custom))
      assert_same registry, registry.clear
    end

    def test_destination_registry_validate_returns_validated_destination
      destination = TestDestinations::CustomDestination.new(:custom)

      assert_same destination, Julewire::Core::Destinations::Registry.validate!(destination)
    end

    def test_destination_registry_copies_copyable_destinations
      original = TestDestinations::CopyableDestination.new(:custom)
      registry = Julewire::Core::Destinations::Registry.new([original])

      first = registry.build(defaults: destination_defaults).fetch(0)
      second = registry.copy.build(defaults: destination_defaults).fetch(0)

      refute_same original, first
      refute_same first, second
      assert_same original, first.copied_from
      assert_same first, second.copied_from
    end

    def test_sink_wrap_defaults_to_non_owning_close
      raw_output = Class.new do
        attr_reader :close_count

        def initialize
          @close_count = 0
        end

        def write(_value); end

        def close
          @close_count += 1
        end
      end.new

      wrapped = Julewire::Core::Destinations::Sink.wrap(raw_output)

      assert_true wrapped.close
      assert_equal 0, raw_output.close_count
    end

    def test_sink_wrap_forwards_owning_close
      raw_output = StringIO.new
      wrapped = Julewire::Core::Destinations::Sink.wrap(raw_output, close_output: true)

      assert_true wrapped.close
      assert_predicate raw_output, :closed?
    end

    def test_sink_wrap_preserves_existing_wrapped_output
      raw_output = StringIO.new
      wrapped = Julewire::Core::Destinations::Sink.wrap(raw_output)

      assert_same wrapped, Julewire::Core::Destinations::Sink.wrap(wrapped, close_output: true)
    end

    def test_sink_wrap_preserves_synchronized_output_subclasses
      raw_output = StringIO.new
      subclass = Class.new(Julewire::Core::Destinations::SynchronizedOutput)
      wrapped = subclass.new(raw_output)

      assert_same wrapped, Julewire::Core::Destinations::Sink.wrap(wrapped)
    end

    def test_sink_wrap_rejects_non_writeable_outputs
      error = assert_raises(ArgumentError) do
        Julewire::Core::Destinations::Sink.wrap(Object.new)
      end

      assert_equal "output must respond to #write", error.message
    end

    def test_custom_destination_requires_name
      destination = Class.new do
        def emit(_record); end
      end.new

      error = assert_raises(ArgumentError) do
        Julewire.configure do |config|
          config.destinations.add(destination)
        end
      end

      assert_equal "destination must respond to #name", error.message
    end

    def test_destination_names_cannot_be_empty
      error = assert_configure_with_default_output_raises do |config|
        config.destinations.use("")
      end

      assert_equal "destination name must not be empty", error.message
    end

    def test_destination_rejects_output_arrays
      error = assert_raises(ArgumentError) do
        Julewire.configure do |config|
          config.destinations.use(
            :multi_output,
            formatter: Julewire::Core::TestHelpers::TestLineFormatter.new("multi"),
            output: [StringIO.new]
          )
        end
      end

      assert_equal "output arrays are transport adapter behavior; use destinations or an adapter output", error.message
    end

    def test_destination_rejects_output_array_subclasses
      output = Class.new(Array).new

      error = assert_raises(ArgumentError) do
        Julewire::Core::Destinations::Sink.wrap(output)
      end

      assert_equal "output arrays are transport adapter behavior; use destinations or an adapter output", error.message
    end

    private

    def destination_defaults(formatter: Julewire::Core::Records::Formatter.new, on_drop: ->(*) {}, on_failure: ->(*) {})
      {
        encoder: Julewire::Core::Serialization::JsonEncoder.new,
        formatter: formatter,
        on_drop: on_drop,
        on_failure: on_failure
      }
    end
  end
end
