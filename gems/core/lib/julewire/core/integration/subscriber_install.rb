# frozen_string_literal: true

module Julewire
  module Core
    module Integration
      # @api integration_spi
      module SubscriberInstall
        def subscriber = @subscription&.subscriber

        def installed? = !subscriber.nil?

        def reset!
          @subscription&.reset
          @subscription = nil
        end

        private

        def update_subscription(configuration)
          @subscription&.update(configuration)
        end

        def store_subscription(subscriber, unsubscribe: nil)
          @subscription = Subscription.new(subscriber, unsubscribe: unsubscribe)
          subscriber
        end

        def install_subscriber(configuration, enabled:)
          return reset! unless enabled
          return update_subscription(configuration) if installed?

          subscriber = new(configuration)
          unsubscribe = yield subscriber
          store_subscription(subscriber, unsubscribe: unsubscribe)
        end
      end
    end
  end
end
