# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestLogSubscriberSilencer < Minitest::Test
    cover Julewire::Rails::LogSubscriberSilencer
    def test_silencer_loads_and_delegates_all_known_subscribers_to_top_level_rails_support
      required = []
      constantized = []
      detached = []
      subscriber_classes = Julewire::Rails::LogSubscriberSilencer::SUBSCRIBERS.to_h do |class_name, _namespace|
        [class_name, Class.new]
      end
      shadow_log_subscribers = Module.new do
        def self.constantize(_name) = raise "nested RailsSupport must not be used"
        def self.detach(_subscriber_class, _namespace) = raise "nested RailsSupport must not be used"
      end
      shadow_rails_support = Module.new
      shadow_rails_support.const_set(:LogSubscribers, shadow_log_subscribers)

      with_constant(Julewire::Rails, :RailsSupport, shadow_rails_support) do
        with_overridden_singleton_method(
          Julewire::Core::Integration::Lifecycle,
          :require_optional,
          proc { |path| required << path }
        ) do
          with_overridden_singleton_method(
            Julewire::RailsSupport::LogSubscribers,
            :constantize,
            proc do |class_name|
              constantized << class_name
              subscriber_classes.fetch(class_name)
            end
          ) do
            with_overridden_singleton_method(
              Julewire::RailsSupport::LogSubscribers,
              :detach,
              proc { |subscriber_class, namespace| detached << [subscriber_class, namespace] }
            ) do
              Julewire::Rails::LogSubscriberSilencer.silence!
            end
          end
        end
      end

      assert_equal Julewire::Rails::LogSubscriberSilencer::LOG_SUBSCRIBER_FILES, required
      assert_equal Julewire::Rails::LogSubscriberSilencer::SUBSCRIBERS.map(&:first), constantized
      assert_equal(
        Julewire::Rails::LogSubscriberSilencer::SUBSCRIBERS.map do |class_name, namespace|
          [subscriber_classes.fetch(class_name), namespace]
        end,
        detached
      )
    end

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
