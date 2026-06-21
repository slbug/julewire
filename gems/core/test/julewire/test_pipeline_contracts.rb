# frozen_string_literal: true

require "test_helper"
require "stringio"

module Julewire
  class TestPipelineContracts < Minitest::Test
    def test_pipeline_rejects_non_duck_formatter_output_and_processors
      assert_raises(ArgumentError) { build_pipeline(formatter: Object.new, output: StringIO.new) }
      assert_raises(ArgumentError) { build_pipeline(output: Object.new) }
      assert_raises(ArgumentError) { build_pipeline(output: StringIO.new, processors: [Object.new]) }
    end

    def test_pipeline_contains_wrong_arity_formatter_at_emit_time
      failures = Queue.new
      drops = Queue.new
      pipeline = build_pipeline(
        formatter: -> { { message: "missing record" } },
        on_drop: ->(reason, _metadata) { drops << reason },
        on_failure: ->(error, metadata) { failures << [error, metadata] },
        output: StringIO.new
      )

      pipeline.emit(message: "format")

      error, metadata = failures.pop

      assert_instance_of ArgumentError, error
      assert_equal :formatter, metadata.fetch(:phase)
      assert_equal 1, pipeline.health.dig(:destinations, :default, :counts, :formatter_error)
      assert_equal [:formatter_error], nonblocking_queue_values(drops)
    end

    def test_pipeline_contains_wrong_arity_output_at_emit_time
      output = Class.new do
        def write
          @called = true
        end
      end.new
      failures = Queue.new
      drops = Queue.new
      pipeline = build_pipeline(
        on_drop: ->(reason, _metadata) { drops << reason },
        on_failure: ->(error, metadata) { failures << [error, metadata] },
        output: output
      )

      pipeline.emit(message: "write")

      error, metadata = failures.pop

      assert_instance_of ArgumentError, error
      assert_equal :output, metadata.fetch(:phase)
      assert_equal 1, pipeline.health.dig(:destinations, :default, :counts, :output_error)
      assert_equal [:output_exception], nonblocking_queue_values(drops)
    end

    def test_pipeline_contains_wrong_arity_processor_at_emit_time
      output = StringIO.new
      pipeline = build_pipeline(
        output: output,
        processors: [-> { { message: "missing record" } }]
      )

      pipeline.emit(message: "process")

      assert_equal 1, pipeline.health.dig(:counts, :processor_error)
      assert_includes output.string, "julewire.processor_error"
    end

    def test_pipeline_rejects_custom_destination_without_emit
      configuration = Julewire::Core::Configuration.new
      error = assert_raises(ArgumentError) do
        configuration.destinations.add(
          Class.new do
            def name = :broken
          end.new
        )
      end

      assert_equal "destination must respond to #emit", error.message
    end

    def test_pipeline_rejects_custom_destination_without_name
      configuration = Julewire::Core::Configuration.new
      error = assert_raises(ArgumentError) do
        configuration.destinations.add(
          Class.new do
            def emit(_record)
              nil
            end
          end.new
        )
      end

      assert_equal "destination must respond to #name", error.message
    end

    def test_on_failure_can_receive_phase_and_record_metadata
      failures = Queue.new
      processor = ->(_record) { raise "processor failed" }
      pipeline = build_pipeline(
        on_failure: lambda do |error, metadata|
          failures << [error, metadata.fetch(:phase), metadata.fetch(:record_metadata)]
        end,
        output: StringIO.new,
        processors: [processor]
      )

      pipeline.emit(source: "app", event: "work", labels: { service: "core" })

      error, phase, metadata = failures.pop

      assert_equal "processor failed", error.message
      assert_equal :processor, phase
      assert_equal "app", metadata.fetch(:source)
      assert_equal "work", metadata.fetch(:event)
      assert_equal({ service: "core" }, metadata.fetch(:labels))
      refute_includes metadata, :payload
    end
  end
end
