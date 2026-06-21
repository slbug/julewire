# frozen_string_literal: true

require "test_helper"
require "stringio"

module Julewire
  class TestLifecycleWarnings < Minitest::Test
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

    def test_reconfigure_reports_old_pipeline_close_failure
      output = FalseCloseOutput.new
      failures = Queue.new

      configure_false_close_output(output, failures)
      Julewire.configure { configure_destination(it, output: StringIO.new) }

      error, metadata = failures.pop

      assert_instance_of Julewire::Core::LifecycleError, error
      assert_lifecycle_warning_metadata(metadata, operation: :configure)
      assert_lifecycle_warning_count
      assert output.closed
    end

    def test_reset_reports_old_pipeline_close_failure
      output = FalseCloseOutput.new
      failures = Queue.new

      configure_false_close_output(output, failures)
      Julewire.reset!

      error, metadata = failures.pop

      assert_instance_of Julewire::Core::LifecycleError, error
      assert_lifecycle_warning_metadata(metadata, operation: :reset)
      assert_lifecycle_warning_count
    end

    def test_close_uses_configured_close_timeout_for_runtime_deadline
      output = FalseCloseOutput.new
      failures = Queue.new

      configure_false_close_output(output, failures)

      refute Julewire.close
      assert output.closed
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
