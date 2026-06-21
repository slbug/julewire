# frozen_string_literal: true

require "support/active_job_test_support"

module Julewire
  class TestActiveJobLogSubscriberSilencer < Minitest::Test
    include ActiveJobTestSupport

    cover Julewire::ActiveJob::LogSubscriberSilencer

    def test_log_subscriber_silencer_returns_without_subscriber
      with_overridden_singleton_method(
        Julewire::Core::Integration::Lifecycle,
        :require_optional,
        proc { |*| }
      ) do
        with_overridden_singleton_method(
          Julewire::ActiveJob::LogSubscriberSilencer,
          :active_job_log_subscriber,
          proc {}
        ) do
          assert_nil Julewire::ActiveJob::LogSubscriberSilencer.silence!
        end
      end
    end

    def test_log_subscriber_path_resolves_against_current_active_job
      refute_nil Julewire::Core::Integration::Lifecycle.require_optional("active_job/log_subscriber")
    end

    def test_log_subscriber_silencer_detaches_and_unsubscribes
      detached = []
      reporter = FakeReporter.new
      subscriber_class = nil

      with_fake_event_reporter_log_subscriber do |log_subscriber|
        subscriber_class = Class.new(log_subscriber) do
          define_singleton_method(:detach_from) { detached << it }
        end

        silence_with_fake_log_subscriber(reporter, subscriber_class)
      end

      assert_equal [:active_job], detached
      assert_equal [subscriber_class], reporter.unsubscriptions
    end

    def test_log_subscriber_silencer_unsubscribes_when_detach_is_unavailable
      reporter = FakeReporter.new
      subscriber_class = nil

      with_fake_event_reporter_log_subscriber do |log_subscriber|
        subscriber_class = Class.new(log_subscriber)

        silence_with_fake_log_subscriber(reporter, subscriber_class)
      end

      assert_equal [subscriber_class], reporter.unsubscriptions
    end

    def test_log_subscriber_silencer_handles_missing_log_subscriber
      with_overridden_singleton_method(
        Julewire::ActiveJob::LogSubscriberSilencer,
        :active_job_log_subscriber,
        proc {}
      ) do
        assert_nil Julewire::ActiveJob::LogSubscriberSilencer.silence!
      end
    end

    private

    def silence_with_fake_log_subscriber(reporter, subscriber_class)
      with_fake_rails_event(reporter) do
        with_overridden_singleton_method(
          Julewire::Core::Integration::Lifecycle,
          :require_optional,
          proc { |*| }
        ) do
          with_overridden_singleton_method(
            Julewire::ActiveJob::LogSubscriberSilencer,
            :active_job_log_subscriber,
            proc { subscriber_class }
          ) do
            Julewire::ActiveJob::LogSubscriberSilencer.silence!
          end
        end
      end
    end
  end
end
