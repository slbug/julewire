# frozen_string_literal: true

module Julewire
  module ActiveJob
    module LogSubscriberSilencer
      class << self
        def silence!
          Core::Integration::Lifecycle.require_optional("active_job/log_subscriber")
          subscriber_class = active_job_log_subscriber
          return unless subscriber_class

          subscriber_class.detach_from(:active_job) if subscriber_class.respond_to?(:detach_from)
          Julewire::RailsSupport::EventReporter.unsubscribe_log_subscriber(subscriber_class)
        end

        private

        def active_job_log_subscriber
          ::ActiveJob::LogSubscriber if defined?(::ActiveJob::LogSubscriber)
        end
      end
    end
  end
end
