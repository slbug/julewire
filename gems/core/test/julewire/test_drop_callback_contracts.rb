# frozen_string_literal: true

require "test_helper"
require "stringio"

module Julewire
  class TestDropCallbackContracts < Minitest::Test
    def test_level_and_no_output_drops_do_not_call_on_drop
      drops = Queue.new
      output = StringIO.new

      Julewire.configure do |config|
        config.level = :warn
        configure_destination(config, output: output)
        config.on_drop = ->(reason, _metadata) { drops << reason }
      end
      Julewire.emit(severity: :info, message: "below")

      Julewire.configure do |config|
        config.destinations.clear
        config.on_drop = ->(reason, _metadata) { drops << reason }
      end
      Julewire.emit(message: "no output")

      assert_raises(ThreadError) { drops.pop(true) }
      assert_empty output.string
      assert_equal 1, Julewire.health.dig(:pipeline, :counts, :no_output_dropped)
    end
  end
end
