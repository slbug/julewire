# frozen_string_literal: true

require "test_helper"
require "stringio"

module Julewire
  class TestPipelineFormatterContracts < Minitest::Test
    class FailingFormatter
      def call(_record)
        raise "format failed"
      end
    end

    class StringFormatter
      def call(_record)
        "already encoded"
      end
    end

    class RawStringEncoder
      def call(payload)
        "#{payload}\n"
      end
    end

    class HashFormatter
      def call(_record)
        { message: "mapped" }
      end
    end

    class NonFiniteFormatter
      def call(_record)
        { value: Float::NAN }
      end
    end

    def test_formatter_errors_are_reported_as_formatter_phase
      configure_formatter(FailingFormatter.new)

      Julewire.emit(message: "format")

      assert_formatter_failure(RuntimeError, "format failed")
      assert_formatter_health
    end

    def test_string_formatter_results_can_be_encoded_by_custom_raw_string_encoder
      output = StringIO.new
      Julewire.configure do |config|
        configure_destination(
          config,
          encoder: RawStringEncoder.new,
          formatter: StringFormatter.new,
          output: output
        )
      end

      Julewire.emit(message: "format")

      assert_equal "already encoded\n", output.string
    end

    def test_json_encoder_serializes_non_finite_custom_formatter_values
      output = StringIO.new
      Julewire.configure do |config|
        configure_destination(config, formatter: NonFiniteFormatter.new, output: output)
      end

      Julewire.emit(message: "format")

      assert_equal "NaN", JSON.parse(output.string).fetch("value")
    end

    private

    def configure_formatter(formatter)
      @drop_events = Queue.new
      @failure_events = Queue.new
      Julewire.configure do |config|
        configure_destination(config, formatter: formatter, output: StringIO.new)
        config.on_drop = ->(reason, _metadata) { @drop_events << reason }
        config.on_failure = ->(error, metadata) { @failure_events << [error, metadata] }
      end
    end

    def assert_formatter_failure(error_class, message)
      error, metadata = @failure_events.pop

      assert_instance_of error_class, error
      assert_equal message, error.message
      assert_equal :formatter, metadata.fetch(:phase)
    end

    def assert_formatter_health
      counts = Julewire.health.dig(:pipeline, :counts)
      destination = destination_health
      destination_counts = destination.fetch(:counts)

      assert_equal 1, counts.fetch(:entered)
      assert_equal 1, destination_counts.fetch(:received)
      assert_equal 1, destination_counts.fetch(:formatter_error)
      assert_equal 0, destination_counts.fetch(:formatted)
      assert_equal 0, destination_counts.fetch(:output_accepted)
      assert_equal 0, destination_counts.fetch(:output_error)
      assert_equal :formatter_error, destination.dig(:last_loss, :reason)
      assert_equal [:formatter_error], nonblocking_queue_values(@drop_events)
    end
  end
end
