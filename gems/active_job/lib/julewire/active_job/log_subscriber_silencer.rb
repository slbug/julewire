# frozen_string_literal: true

module Julewire
  module ActiveJob
    module LogSubscriberSilencer
      class << self
        def silence!
          Core::Integration::Lifecycle.require_optional("active_job/log_subscriber")
          subscriber_class = ::ActiveJob::LogSubscriber if defined?(::ActiveJob::LogSubscriber)
          Julewire::RailsSupport::LogSubscribers.detach(subscriber_class, :active_job)
        end
      end
    end
  end
end
