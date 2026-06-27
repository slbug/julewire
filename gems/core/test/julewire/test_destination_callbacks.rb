# frozen_string_literal: true

require "test_helper"
require "stringio"

module Julewire
  class TestDestinationCallbacks < Minitest::Test
    cover Julewire::Core::Destinations::Destination
    cover Julewire::Core::Diagnostics::CallbackNotifier
    cover "Julewire::Core::Processing::Pipeline#destination_defaults"
    class FailingOutput
      def write(_value)
        raise "write failed"
      end
    end

    def test_destination_can_override_failure_callback
      global_failures = Queue.new
      local_failures = Queue.new

      Julewire.configure do |config|
        configure_destination(config, output: StringIO.new)
        config.on_failure = ->(error, _metadata) { global_failures << error }
        config.destinations.use(
          :local,
          formatter: Julewire::Core::TestHelpers::TestLineFormatter.new("local"),
          output: FailingOutput.new,
          on_failure: ->(error, metadata) { local_failures << [error, metadata] }
        )
      end

      Julewire.emit(message: "work")

      error, metadata = safe_queue_pop(local_failures)

      assert_equal "write failed", error.message
      assert_equal :output, metadata.fetch(:phase)
      assert_empty nonblocking_queue_values(global_failures)
    end

    def test_destination_can_override_drop_callback
      global_drops = Queue.new
      local_drops = Queue.new
      output = StringIO.new

      Julewire.configure do |config|
        configure_destination(config, output: StringIO.new)
        config.on_drop = ->(reason, _metadata) { global_drops << reason }
        config.destinations.use(
          :tiny,
          formatter: Julewire::Core::TestHelpers::TestLineFormatter.new("tiny"),
          output: output,
          max_record_bytes: 3,
          on_drop: ->(reason, metadata) { local_drops << [reason, metadata] }
        )
      end

      Julewire.emit(message: "work", source: "test.destination")

      reason, metadata = safe_queue_pop(local_drops)
      health = Julewire.health.dig(:pipeline, :destinations, :tiny)

      assert_equal :record_too_large, reason
      assert_equal :tiny, metadata.fetch(:destination)
      assert_equal :destination, metadata.fetch(:phase)
      assert_equal :record_too_large, metadata.fetch(:reason)
      assert_equal "log", metadata.dig(:record_metadata, :event)
      assert_equal :info, metadata.dig(:record_metadata, :severity)
      assert_equal "test.destination", metadata.dig(:record_metadata, :source)
      assert_operator metadata.fetch(:bytesize), :>, metadata.fetch(:max_record_bytes)
      assert_equal "test.destination", health.dig(:last_loss, :source)
      assert_predicate health.dig(:last_loss, :at), :utc?
      assert_empty nonblocking_queue_values(global_drops)
    end

    def test_destination_drop_callback_failure_keeps_callback_failure_snapshot
      Julewire.configure do |config|
        configure_destination(config, output: StringIO.new, max_record_bytes: 3)
        config.on_drop = ->(_reason, _metadata) { raise "drop callback failed" }
      end

      Julewire.emit(message: "work")

      health = Julewire.health.dig(:pipeline, :destinations, :default)

      assert_equal 1, health.dig(:counts, :callback_error)
      assert_equal "RuntimeError", health.dig(:last_callback_failure, :class)
      assert_equal :record_too_large, health.dig(:last_callback_failure, :reason)
    end
  end
end
