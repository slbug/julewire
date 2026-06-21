# frozen_string_literal: true

require "test_helper"
require "stringio"

module Julewire
  class TestRuntimeLifecycleApi < Minitest::Test
    class LifecycleOutput
      attr_reader :flush_count

      def write(_value); end

      def flush
        @flush_count = flush_count.to_i + 1
      end
    end

    def test_lifecycle_methods_reject_invalid_timeouts
      assert_invalid_lifecycle_timeout { Julewire.flush(timeout: -1) }
      assert_invalid_lifecycle_timeout { Julewire.close(timeout: "slow") }
      assert_invalid_lifecycle_timeout { Julewire.flush(timeout: Float::INFINITY) }
      assert_invalid_lifecycle_timeout { Julewire.flush(timeout: -Float::INFINITY) }
      assert_invalid_lifecycle_timeout { Julewire.flush(timeout: Float::NAN) }
    end

    def test_invalid_close_timeout_leaves_runtime_open
      output = StringIO.new
      Julewire.configure { configure_destination(it, output: output) }

      assert_invalid_lifecycle_timeout { Julewire.close(timeout: "slow") }
      Julewire.emit(message: "still open")

      refute Julewire.health.fetch(:closed)
      assert_includes output.string, "still open"
    end

    def test_flush_uses_configured_pipeline_timeout_for_runtime_deadline
      output = LifecycleOutput.new

      Julewire.configure do |config|
        configure_destination(config, output: output)
        config.pipeline_close_timeout = 0.25
      end

      Julewire.flush

      assert_equal 1, output.flush_count
    end

    def test_explicit_nil_flush_timeout_remains_unbounded
      output = LifecycleOutput.new

      Julewire.configure do |config|
        configure_destination(config, output: output)
        config.pipeline_close_timeout = 0.25
      end

      Julewire.flush(timeout: nil)

      assert_equal 1, output.flush_count
    end

    def test_emit_after_close_is_noop_until_reconfigure
      output = StringIO.new
      drops = configure_output_with_drop_capture(output)

      Julewire.emit(message: "before")

      assert Julewire.close(timeout: 1)

      Julewire.emit(message: "after")

      reason, metadata = drops.pop(timeout: 1)
      health = Julewire.health

      assert_includes output.string, "before"
      refute_includes output.string, "after"
      assert_equal :runtime_closed, reason
      assert_equal :runtime, metadata.fetch(:phase)
      assert health.fetch(:closed)
      assert_equal 1, health.dig(:counts, :post_close_emits)
      assert_equal 1, health.dig(:pipeline, :counts, :entered)
    end

    def test_post_close_drop_callback_failures_are_counted
      configure_default_output_with_callback(
        StringIO.new,
        :on_drop,
        ->(_reason, _metadata) { raise "drop callback failed" }
      )

      Julewire.close(timeout: 1)
      previous_counts = Julewire.health.fetch(:counts)
      Julewire.emit(message: "after")

      health = Julewire.health

      assert_equal 1, health.dig(:counts, :post_close_emits)
      callback_failures = health.dig(:counts, :runtime_callback_failures) -
                          previous_counts.fetch(:runtime_callback_failures)

      assert_equal 1, callback_failures
    end

    def test_post_close_drop_callbacks_fire_for_each_drop
      drops = Queue.new
      Julewire.configure do |config|
        configure_destination(config, output: StringIO.new)
        config.on_drop = ->(reason, _metadata) { drops << reason }
      end
      previous_counts = Julewire.health.fetch(:counts)

      Julewire.close(timeout: 1)
      2.times { Julewire.emit(message: "after") }

      health = Julewire.health

      assert_equal %i[runtime_closed runtime_closed], nonblocking_queue_values(drops)
      assert_equal 2, health.dig(:counts, :post_close_emits)
      assert_runtime_count_delta health, previous_counts, :post_close_emits_total, 2
    end

    def test_reconfigure_after_close_installs_fresh_open_pipeline
      first_output = StringIO.new
      second_output = StringIO.new
      previous_counts = Julewire.health.fetch(:counts)

      Julewire.configure { configure_destination(it, output: first_output) }
      Julewire.close(timeout: 1)
      Julewire.emit(message: "dropped")

      Julewire.configure { configure_destination(it, output: second_output) }
      Julewire.emit(message: "written")

      health = Julewire.health

      refute health.fetch(:closed)
      assert_equal 0, health.dig(:counts, :post_close_emits)
      assert_runtime_count_delta health, previous_counts, :post_close_emits_total, 1
      refute_includes first_output.string, "dropped"
      assert_includes second_output.string, "written"
    end

    private

    def assert_invalid_lifecycle_timeout(&)
      error = assert_raises(ArgumentError, &)

      assert_match "timeout must be nil or a non-negative finite Numeric", error.message
    end

    def assert_runtime_count_delta(health, previous_counts, key, expected_delta)
      assert_equal expected_delta, health.dig(:counts, key) - previous_counts.fetch(key)
    end
  end
end
