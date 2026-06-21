# frozen_string_literal: true

require "test_helper"
require "json"
require "stringio"

module Julewire
  class TestDestinations < Minitest::Test
    cover Julewire::Core::Destinations::Definition
    cover Julewire::Core::Destinations::Destination

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

      error, metadata = failures.pop

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

      error, metadata = failures.pop

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
      assert_in_delta 0.1, Julewire.health.dig(:pipeline, :destinations, :transport, :flushed_timeout), 0.001
    end

    def test_custom_destination_nil_lifecycle_result_is_successful
      destination = CapturingDestination.new(:transport)

      Julewire.configure do |config|
        config.destinations.add(destination)
      end

      assert Julewire.flush
      assert Julewire.close
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
  end

  class TestDestinationChaosContract < Minitest::Test
    cover Julewire::Core::Destinations::Destination
    cover Julewire::Core::Testing::Chaos::Destination

    def test_direct_destination_satisfies_destination_chaos_contract
      Julewire::Testing::Chaos.assert_destination_chaos_contract(
        self,
        record: build_record({ message: "chaos", severity: :info }),
        formatter: ->(error) { formatter_chaos_destination(error) },
        encoder: ->(error) { encoder_chaos_destination(error) },
        output: ->(error) { build_destination(output: raising_output(error)) },
        callbacks: ->(error) { callback_chaos_destination(error) }
      )
    end

    private

    def formatter_chaos_destination(error)
      build_destination(
        output: StringIO.new,
        formatter: Julewire::Testing::Chaos.raiser(error)
      )
    end

    def encoder_chaos_destination(error)
      build_destination(
        output: StringIO.new,
        encoder: Julewire::Testing::Chaos.raiser(error)
      )
    end

    def raising_output(error)
      Object.new.tap do |output|
        output.define_singleton_method(:write) { |_value| raise error }
      end
    end

    def callback_chaos_destination(error)
      trigger = RuntimeError.new("formatter trigger")
      build_destination(
        output: StringIO.new,
        formatter: Julewire::Testing::Chaos.raiser(trigger),
        on_drop: Julewire::Testing::Chaos.raiser(error),
        on_failure: Julewire::Testing::Chaos.raiser(error)
      )
    end
  end

  class TestDestinationDefinitionValidation < Minitest::Test
    cover Julewire::Core::Destinations::Definition

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

    def test_destination_rejects_nil_output_when_constructed_directly
      error = assert_raises(ArgumentError) do
        build_destination(output: nil, name: :direct)
      end

      assert_equal "destination :direct output is required", error.message
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

    def test_destination_definition_requires_output_after_defaults_are_available
      definition = Julewire::Core::Destinations::Definition.new(:direct)

      error = assert_raises(ArgumentError) { definition.build(defaults: destination_defaults) }

      assert_equal "destination :direct output is required", error.message
    end

    def test_destination_definition_uses_inherited_defaults
      output = StringIO.new
      formatter = Julewire::Core::TestHelpers::TestLineFormatter.new("direct")
      definition = Julewire::Core::Destinations::Definition.new(:direct, output: output)
      destination = definition.build(defaults: destination_defaults(formatter: formatter))

      destination.emit(build_contract_record(message: "hello"))
      destination.close

      assert_equal({ "line" => "direct:hello" }, JSON.parse(output.string))
      refute_predicate output, :closed?
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

    private

    def destination_defaults(formatter: Julewire::Core::Records::Formatter.new)
      {
        encoder: Julewire::Core::Serialization::JsonEncoder.new,
        error_backtrace_lines: 0,
        formatter: formatter,
        on_drop: ->(*) {},
        on_failure: ->(*) {}
      }
    end
  end
end
