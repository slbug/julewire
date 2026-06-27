# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestCustomDestinationDrops < Minitest::Test
    cover Julewire::Core::Destinations::Destination
    cover "Julewire::Core::Processing::Pipeline#record_destination_drop"

    class CallbackDestination
      attr_reader :name

      def initialize(name:, result: nil, error: nil)
        @name = name
        @result = result
        @error = error
      end

      def emit(_record)
        raise @error if @error

        @result
      end

      def flush(timeout: nil); end

      def close(timeout: nil); end

      def health = { status: :ok }
    end

    def test_custom_destination_failure_is_reported_as_drop
      failures = Queue.new
      drops = Queue.new
      destination = CallbackDestination.new(name: :raising, error: RuntimeError.new("destination failed"))

      Julewire.configure do |config|
        config.on_drop = ->(reason, metadata) { drops << [reason, metadata] }
        config.on_failure = ->(error, metadata) { failures << [error, metadata] }
        config.destinations.add(destination)
      end
      Julewire.emit(source: "app", event: "work", message: "work")

      error, failure_metadata = safe_queue_pop(failures)
      reason, drop_metadata = safe_queue_pop(drops)

      assert_equal "destination failed", error.message
      assert_equal :destination_exception, reason
      assert_equal :raising, failure_metadata.fetch(:destination)
      assert_equal :raising, drop_metadata.fetch(:destination)
      assert_equal "work", drop_metadata.dig(:record_metadata, :event)
    end

    def test_custom_destination_false_result_is_reported_as_drop
      drops = Queue.new
      destination = CallbackDestination.new(name: :rejecting, result: false)

      Julewire.configure do |config|
        config.on_drop = ->(reason, metadata) { drops << [reason, metadata] }
        config.destinations.add(destination)
      end
      Julewire.emit(source: "app", event: "work", message: "work")

      reason, metadata = safe_queue_pop(drops)

      assert_equal :destination_rejected, reason
      assert_equal :rejecting, metadata.fetch(:destination)
      assert_equal "work", metadata.dig(:record_metadata, :event)
      pipeline = Julewire.health.fetch(:pipeline)

      assert_equal 0, pipeline.dig(:counts, :callback_error)
      assert_equal 0, pipeline.dig(:counts, :failures)
      assert_nil pipeline.fetch(:last_callback_failure)
      assert_nil pipeline.fetch(:last_failure)
    end

    def test_custom_destination_drop_callback_failure_is_reported_on_pipeline
      destination = CallbackDestination.new(name: :rejecting, result: false)

      Julewire.configure do |config|
        config.on_drop = lambda do |_reason, metadata|
          raise "drop failed #{metadata.fetch(:reason)}"
        end
        config.destinations.add(destination)
      end
      Julewire.emit(source: "app", event: "work", message: "work")

      pipeline = Julewire.health.fetch(:pipeline)

      assert_equal 1, pipeline.dig(:counts, :callback_error)
      assert_equal "RuntimeError", pipeline.dig(:last_callback_failure, :class)
      assert_equal :destination_rejected, pipeline.dig(:last_callback_failure, :reason)
    end
  end
end
