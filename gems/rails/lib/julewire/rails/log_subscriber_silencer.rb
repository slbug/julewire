# frozen_string_literal: true

require "active_support/log_subscriber"

module Julewire
  module Rails
    module LogSubscriberSilencer
      SUBSCRIBERS = [
        ["ActionController::LogSubscriber", :action_controller],
        ["ActionDispatch::LogSubscriber", :action_dispatch],
        ["ActionView::LogSubscriber", :action_view],
        ["ActiveRecord::LogSubscriber", :active_record]
      ].freeze

      LOG_SUBSCRIBER_FILES = %w[
        action_controller/log_subscriber
        action_dispatch/log_subscriber
        action_view/log_subscriber
        active_record/log_subscriber
      ].freeze

      class << self
        def silence!
          require_log_subscribers
          SUBSCRIBERS.each { |class_name, namespace| detach(class_name, namespace) }
        end

        private

        def require_log_subscribers
          LOG_SUBSCRIBER_FILES.each { Core::Integration::Lifecycle.require_optional(it) }
        end

        def detach(class_name, namespace)
          subscriber_class = constantize(class_name)
          return if subscriber_class.nil?

          subscriber_class.detach_from(namespace) if subscriber_class.respond_to?(:detach_from)
          Julewire::RailsSupport::EventReporter.unsubscribe_log_subscriber(subscriber_class)
        end

        def constantize(class_name)
          class_name.split("::").reject(&:empty?).inject(Object) do |namespace, constant_name|
            break unless namespace.const_defined?(constant_name, false)

            namespace.const_get(constant_name, false)
          end
        end
      end
    end
  end
end
