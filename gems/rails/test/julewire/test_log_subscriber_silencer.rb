# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestLogSubscriberSilencer < Minitest::Test
    def test_silencer_removes_real_rails_head_event_reporter_subscriber
      skip "Rails head only" unless ENV["JULEWIRE_RAILS_APPRAISAL"] == "rails_head"

      Julewire::Core::Integration::Lifecycle.require_optional("action_controller/log_subscriber")
      event_reporter = ::ActiveSupport.event_reporter
      subscriber_class = ::ActionController::LogSubscriber

      event_reporter.unsubscribe(subscriber_class)
      event_reporter.subscribe(subscriber_class.new, &subscriber_class.subscription_filter)

      assert_equal 1, subscriber_count(event_reporter, subscriber_class)

      Julewire::Rails::LogSubscriberSilencer.silence!

      assert_equal 0, subscriber_count(event_reporter, subscriber_class)
    end

    private

    def subscriber_count(event_reporter, subscriber_class)
      event_reporter.subscribers.count { it.fetch(:subscriber).is_a?(subscriber_class) }
    end
  end
end
