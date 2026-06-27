# frozen_string_literal: true

require "test_helper"
require "stringio"

module Julewire
  class TestLifecycleWarnings < Minitest::Test
    cover Julewire::Core::LifecycleError
    cover "Julewire::Core::Runtime#configure"
    cover "Julewire::Core::Runtime#notify_lifecycle_warning"
    cover "Julewire::Core::Runtime#report_pipeline_close_result"
    cover "Julewire::Core::Runtime#record_lifecycle_warning"
    cover "Julewire::Core::Runtime#reset!"
    cover "Julewire::Core::Runtime#reset_under_lock"

    class FalseCloseOutput
      attr_reader :closed

      def initialize
        @close = false
      end

      def write(_value)
        @written = true
      end

      def close
        @closed = true
        @close
      end
    end

    def test_configure_rejects_reset_from_inside_configure
      assert_runtime_call_rejected_inside_configure(:reset!) { Julewire.reset! }
    end

    def test_reset_reports_old_pipeline_close_failure
      output = FalseCloseOutput.new
      failures = Queue.new

      configure_false_close_output(output, failures)
      Julewire.reset!

      error, metadata = safe_queue_pop(failures)

      assert_instance_of Julewire::Core::LifecycleError, error
      assert_equal "Julewire pipeline close returned false", error.message
      assert_lifecycle_warning_metadata(metadata, operation: :reset)
      assert_lifecycle_warning_count
    end

    def test_reset_close_failure_records_callback_failure
      output = FalseCloseOutput.new
      before = Julewire.health.dig(:counts, :runtime_callback_failures)

      Julewire.configure do |config|
        configure_destination(config, output: output, close_output: true)
        config.on_failure = ->(_error, _metadata) { raise "callback failed" }
      end

      Julewire.reset!

      health = Julewire.health

      assert_equal before + 1, health.dig(:counts, :runtime_callback_failures)
      assert_equal "RuntimeError", health.dig(:last_callback_failure, :class)
      assert_equal :close, health.dig(:last_callback_failure, :action)
      assert_lifecycle_warning_count
    end

    def test_reconfigure_does_not_report_successful_pipeline_close
      failures = Queue.new
      Julewire.configure do |config|
        configure_destination(config, output: StringIO.new)
        config.on_failure = ->(error, metadata) { failures << [error, metadata] }
      end
      before = Julewire.health.dig(:counts, :lifecycle_warnings)

      Julewire.configure { configure_destination(it, output: StringIO.new) }

      assert_equal before, Julewire.health.dig(:counts, :lifecycle_warnings)
      assert_raises(ThreadError) { failures.pop(true) }
    end

    def test_reset_counts_attempt
      before = Julewire.health.dig(:counts, :reset_attempts)

      Julewire.reset!

      assert_equal before + 1, Julewire.health.dig(:counts, :reset_attempts)
    end

    def test_close_uses_configured_close_timeout_for_runtime_deadline
      output = FalseCloseOutput.new
      failures = Queue.new

      configure_false_close_output(output, failures)

      assert_false Julewire.close
      assert_true output.closed
    end

    private

    def configure_false_close_output(output, failures)
      Julewire.configure do |config|
        configure_destination(config, output: output, close_output: true)
        config.on_failure = ->(error, metadata) { failures << [error, metadata] }
        config.pipeline_close_timeout = 0.25
      end
    end

    def assert_lifecycle_warning_metadata(metadata, operation:)
      assert_equal :close, metadata.fetch(:action)
      assert_equal operation, metadata.fetch(:operation)
      assert_equal :pipeline_teardown, metadata.fetch(:phase)
      assert_operator metadata.fetch(:timeout), :>=, 0
    end

    def assert_lifecycle_warning_count
      assert_operator Julewire.health.dig(:counts, :lifecycle_warnings), :>=, 1
    end
  end
end
