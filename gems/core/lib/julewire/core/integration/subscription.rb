# frozen_string_literal: true

module Julewire
  module Core
    module Integration
      # @api integration_spi
      class Subscription
        attr_reader :subscriber

        def initialize(subscriber, unsubscribe: nil)
          @subscriber = subscriber
          @unsubscribe = unsubscribe
        end

        def update(configuration)
          @subscriber.configuration = configuration
          @subscriber
        end

        def reset
          @unsubscribe&.call
          nil
        rescue StandardError
          nil
        end
      end
    end
  end
end
