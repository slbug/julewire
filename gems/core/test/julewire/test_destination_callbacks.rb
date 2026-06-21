# frozen_string_literal: true

require "test_helper"
require "stringio"

module Julewire
  class TestDestinationCallbacks < Minitest::Test
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

      error, metadata = local_failures.pop

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

      Julewire.emit(message: "work")

      reason, metadata = local_drops.pop

      assert_equal :record_too_large, reason
      assert_equal :destination, metadata.fetch(:phase)
      assert_empty nonblocking_queue_values(global_drops)
    end
  end
end
