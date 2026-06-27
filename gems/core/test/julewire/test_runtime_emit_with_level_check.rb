# frozen_string_literal: true

require "test_helper"
require "stringio"

module Julewire
  class TestRuntimeEmitWithLevelCheck < Minitest::Test
    cover "Julewire::Core::Runtime#emit_with_level_check"

    def test_pipeline_failure_is_reported_as_an_emit_action
      failures = Queue.new
      runtime = Julewire::Core::RuntimeLocator.current
      runtime.configure do |config|
        config.destinations.use(:default, output: StringIO.new)
        config.on_failure = ->(error, _metadata) { failures << error }
      end
      pipeline = runtime.__send__(:runtime_state).pipeline

      with_overridden_singleton_method(pipeline, :emit, proc { |*| raise "escaped pipeline failure" }) do
        assert_nil runtime.emit(message: "lost")
      end

      assert_equal "escaped pipeline failure", safe_queue_pop(failures).message
      assert_equal :emit, runtime.health.dig(:last_failure, :action)
    end
  end
end
