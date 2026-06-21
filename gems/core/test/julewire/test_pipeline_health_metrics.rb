# frozen_string_literal: true

require "test_helper"
require "stringio"

module Julewire
  class PipelineHealthFailingOutput
    def write(_value)
      raise "write failed"
    end
  end

  class PipelineHealthCountingFormatter
    attr_reader :calls

    def initialize
      @calls = 0
    end

    def call(record)
      @calls += 1
      record.to_h
    end
  end

  class TestPipelineHealthMetrics < Minitest::Test
    def test_pipeline_health_counts_output_accepted_and_level_dropped_records
      output = StringIO.new

      Julewire.configure do |config|
        config.level = :info
        configure_destination(config, output: output)
      end

      Julewire.emit(severity: :debug, message: "drop")
      Julewire.emit(severity: :info, message: "write")

      counts = Julewire.health.dig(:pipeline, :counts)
      destination_counts = destination_health.fetch(:counts)

      assert_equal 1, counts.fetch(:level_dropped)
      assert_equal 1, counts.fetch(:entered)
      assert_equal 1, destination_counts.fetch(:formatted)
      assert_equal 1, destination_counts.fetch(:output_accepted)
      assert_equal 0, destination_counts.fetch(:formatter_error)
      assert_equal 0, destination_counts.fetch(:output_error)
      assert_equal 0, counts.fetch(:processor_error)
    end

    def test_pipeline_health_counts_output_errors
      Julewire.configure { configure_destination(it, output: PipelineHealthFailingOutput.new) }

      Julewire.emit(message: "output")

      counts = Julewire.health.dig(:pipeline, :counts)
      destination_counts = destination_health.fetch(:counts)

      assert_equal 1, counts.fetch(:entered)
      assert_equal 1, destination_counts.fetch(:output_error)
      assert_equal 1, destination_counts.fetch(:formatted)
      assert_equal 0, destination_counts.fetch(:output_accepted)
    end

    def test_synchronous_output_failures_are_counted_per_attempt
      failures = Queue.new
      drops = Queue.new
      formatter = PipelineHealthCountingFormatter.new

      configure_failing_output(formatter: formatter, failures: failures, drops: drops)

      3.times { Julewire.emit(message: "output") }

      health = Julewire.health

      assert_output_failure_health(health)
      assert_output_failure_metadata(failures.pop)
      assert_equal %i[output_exception output_exception output_exception], nonblocking_queue_values(drops)
      assert_equal 3, health.dig(:pipeline, :destinations, :default, :counts, :output_exception)
      assert_equal 3, formatter.calls
    end

    def test_pipeline_health_counts_processor_errors
      output = StringIO.new

      Julewire.configure do |config|
        configure_destination(config, output: output)
        config.processors.use { |_record| raise "processor failed" }
      end

      Julewire.emit(message: "processor")

      counts = Julewire.health.dig(:pipeline, :counts)
      destination_counts = destination_health.fetch(:counts)

      assert_equal 1, counts.fetch(:processor_error)
      assert_equal 1, destination_counts.fetch(:formatted)
      assert_equal 1, destination_counts.fetch(:output_accepted)
      assert_includes output.string, "julewire.processor_error"
    end

    def test_pipeline_drops_encoded_records_over_max_record_bytes
      output = StringIO.new
      drops = Queue.new

      Julewire.configure do |config|
        configure_destination(config, output: output, max_record_bytes: 8)
        config.on_drop = lambda do |reason, metadata|
          drops << [reason, metadata]
        end
      end

      Julewire.emit(message: "too large")

      reason, metadata = drops.pop
      health = Julewire.health

      assert_empty output.string
      assert_equal :record_too_large, reason
      assert_operator metadata.fetch(:bytesize), :>, metadata.fetch(:max_record_bytes)
      assert_equal 1, health.dig(:pipeline, :destinations, :default, :counts, :record_too_large)
      assert_equal :record_too_large, health.dig(:pipeline, :destinations, :default, :last_loss, :reason)
      assert_equal 0, health.dig(:pipeline, :destinations, :default, :counts, :output_accepted)
    end

    private

    def configure_failing_output(formatter:, failures:, drops:)
      Julewire.configure do |config|
        configure_destination(config, formatter: formatter, output: PipelineHealthFailingOutput.new)
        config.on_failure = ->(error, metadata) { failures << [error, metadata] }
        config.on_drop = ->(reason, _metadata) { drops << reason }
      end
    end

    def assert_output_failure_metadata(failure)
      error, metadata = failure

      assert_instance_of RuntimeError, error
      assert_equal :output, metadata.fetch(:phase)
      assert_equal :write, metadata.fetch(:action)
      assert_equal "log", metadata.dig(:record_metadata, :event)

      health = destination_health

      assert_equal 3, health.dig(:counts, :failures)
      assert_equal :output, health.dig(:last_failure, :phase)
      assert_equal :write, health.dig(:last_failure, :action)
      assert_equal "RuntimeError", health.dig(:last_failure, :class)
      assert_equal PipelineHealthFailingOutput.name, health.dig(:last_failure, :output_class)
      assert_equal "log", health.dig(:last_failure, :record, :event)
    end

    def assert_output_failure_health(health)
      destination = health.fetch(:pipeline).fetch(:destinations).fetch(:default)

      assert_equal 3, destination.dig(:counts, :output_error)
      assert_equal 3, destination.dig(:counts, :output_exception)
    end
  end
end
