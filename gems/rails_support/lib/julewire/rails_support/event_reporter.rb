# frozen_string_literal: true

module Julewire
  module RailsSupport
    module EventReporter
      class << self
        def default
          rails = top_level_constant(:Rails)
          return rails.event if rails.respond_to?(:event)

          active_support = top_level_constant(:ActiveSupport)
          return unless active_support.respond_to?(:event_reporter)

          active_support.event_reporter
        end

        def subscribe(reporter, subscriber, &)
          return unless subscribable?(reporter)

          reporter.subscribe(subscriber, &)
          unsubscriber(reporter, subscriber)
        end

        def subscribable?(reporter)
          reporter.respond_to?(:subscribe)
        end

        def unsubscriber(reporter, subscriber)
          -> { reporter.unsubscribe(subscriber) if reporter.respond_to?(:unsubscribe) }
        end

        def unsubscribe_log_subscriber(subscriber_class, reporter: default)
          return unless reporter.respond_to?(:unsubscribe)
          return unless log_subscriber?(subscriber_class)

          reporter.unsubscribe(subscriber_class)
        end

        private

        def log_subscriber?(subscriber_class)
          active_support = top_level_constant(:ActiveSupport)
          event_reporter = active_support.const_get(:EventReporter, false)
          subscriber_class < event_reporter.const_get(:LogSubscriber, false)
        rescue StandardError
          false
        end

        def top_level_constant(name)
          Object.const_get(name, false)
        rescue NameError
          nil
        end
      end
    end
  end
end
