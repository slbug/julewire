# frozen_string_literal: true

require "support/active_job_test_support"

module Julewire
  class TestActiveJobConfiguration < Minitest::Test
    cover Julewire::ActiveJob::Configuration
    cover "Julewire::ActiveJob.install!"
    cover "Julewire::ActiveJob.perform"
    include ActiveJobTestSupport

    def test_configure_and_perform_public_helpers
      Julewire::ActiveJob.configure { it.summary_event = "custom.completed" }
      records = capture_records

      result = Julewire::ActiveJob.perform(fake_job) { "ok" }
      summary = records.find { it[:kind] == :summary }

      assert_equal "ok", result
      assert_equal "custom.completed", summary.fetch(:event)
      assert_equal "job-1", summary.dig(:execution, :id)
    ensure
      Julewire::ActiveJob.reset!
    end

    def test_public_install_forwards_base_reporter_and_configuration
      Julewire::ActiveJob::Subscribers::Event.reset!
      reporter = FakeReporter.new
      configuration = Julewire::ActiveJob::Configuration.new
      configuration.silence_log_subscriber = false
      configuration.event_prefixes = ["forwarded."]
      base = Class.new(FakeBase)

      with_overridden_singleton_method(Julewire::Core::Integration::Lifecycle, :require_optional, proc { |*| }) do
        installed = Julewire::ActiveJob.install!(base: base, event_reporter: reporter, configuration: configuration)

        assert_same base, installed
      end

      subscriber = reporter.subscriptions.fetch(0).fetch(0)

      assert_same configuration, Julewire::ActiveJob.config
      assert_includes base.inherited_modules, Julewire::ActiveJob::JobSerialization
      assert_equal 1, base.callbacks.length
      assert_true subscriber.accept?(name: "forwarded.event")
      assert_false subscriber.accept?(name: "active_job.perform")
    ensure
      Julewire::ActiveJob::Subscribers::Event.reset!
      Julewire::ActiveJob.reset!
    end

    def test_public_install_accepts_default_base_when_disabled
      configuration = Julewire::ActiveJob::Configuration.new
      configuration.enabled = false

      assert_nil Julewire::ActiveJob.install!(configuration: configuration)
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
