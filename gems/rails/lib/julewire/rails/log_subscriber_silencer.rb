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
          SUBSCRIBERS.each do |class_name, namespace|
            subscriber_class = Julewire::RailsSupport::LogSubscribers.constantize(class_name)
            Julewire::RailsSupport::LogSubscribers.detach(subscriber_class, namespace)
          end
        end

        private

        def require_log_subscribers
          LOG_SUBSCRIBER_FILES.each { Core::Integration::Lifecycle.require_optional(it) }
        end
      end
    end
  end
end
