# frozen_string_literal: true

require "support/active_job_test_support"

module Julewire
  class TestActiveJobConfiguration < Minitest::Test
    include ActiveJobTestSupport

    cover Julewire::ActiveJob::Configuration

    def test_that_it_has_a_version_number
      refute_nil ::Julewire::ActiveJob::VERSION
    end

    def test_configure_and_perform_public_helpers
      Julewire::ActiveJob.configure { it.summary_event = "custom.completed" }
      records = capture_records

      result = Julewire::ActiveJob.perform(fake_job) { "ok" }

      assert_equal "ok", result
      assert_equal "custom.completed", records.find { it[:kind] == :summary }.fetch(:event)
    ensure
      Julewire::ActiveJob.reset!
    end

    def test_configure_requires_block
      error = assert_raises(ArgumentError) { Julewire::ActiveJob.configure }

      assert_equal "Julewire::ActiveJob.configure requires a block", error.message
    end

    def test_config_can_be_assigned_and_reset
      configuration = Julewire::ActiveJob::Configuration.new
      configuration.summary_event = "assigned.completed"

      Julewire::ActiveJob.config = configuration

      assert_same configuration, Julewire::ActiveJob.config

      Julewire::ActiveJob.reset!

      refute_same configuration, Julewire::ActiveJob.config
      assert_equal "job.completed", Julewire::ActiveJob.config.summary_event
    end
  end
end
