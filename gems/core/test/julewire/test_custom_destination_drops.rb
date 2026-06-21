# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestCustomDestinationDrops < Minitest::Test
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

      error, failure_metadata = failures.pop
      reason, drop_metadata = drops.pop

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

      reason, metadata = drops.pop

      assert_equal :destination_rejected, reason
      assert_equal :rejecting, metadata.fetch(:destination)
      assert_equal "work", metadata.dig(:record_metadata, :event)
    end
  end
end
