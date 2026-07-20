# frozen_string_literal: true

module Julewire
  module RailsSupport
    module LogSubscribers
      class << self
        def detach(subscriber_class, namespace)
          subscriber_class.detach_from(namespace) if subscriber_class.respond_to?(:detach_from)
          EventReporter.unsubscribe_log_subscriber(subscriber_class)
        end

        def constantize(name)
          Object.const_get(name, false)
        rescue NameError
          nil
        end
      end
    end
  end
end
