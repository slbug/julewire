# frozen_string_literal: true

require "test_helper"
require "stringio"

module Julewire
  class TestRuntimeCallbackFailures < Minitest::Test
    def test_summary_finalizer_callback_failures_are_counted
      runtime = failing_summary_runtime

      runtime.configure do |config|
        configure_destination(config, output: StringIO.new)
        config.on_failure = ->(_error, _metadata) { raise "callback failed" }
      end

      runtime.with_execution(type: :job) { :done }

      health = runtime.health

      assert_equal 1, health.dig(:counts, :runtime_callback_failures)
      assert_equal 1, health.dig(:counts, :runtime_failures)
      assert_equal :summary_finalizer, health.dig(:last_failure, :phase)
      assert_equal "RuntimeError", health.dig(:last_callback_failure, :class)
      assert_equal :summary_finalizer, health.dig(:last_callback_failure, :phase)
    end

    private

    def failing_summary_runtime
      Class.new(Julewire::Core::Runtime) do
        def emit_summary_record(_scope)
          raise "summary failed"
        end
      end.new
    end
  end
end
