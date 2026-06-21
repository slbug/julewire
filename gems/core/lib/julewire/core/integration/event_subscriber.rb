# frozen_string_literal: true

module Julewire
  module Core
    module Integration
      # @api integration_spi
      module EventSubscriber
        class << self
          def included(base)
            base.extend(ClassMethods)
          end
        end

        module ClassMethods
          def event_subscriber(integration_health:, configuration_class:, component: :event_subscriber)
            event_subscriber_options[:component] = component
            event_subscriber_options[:configuration_class] = configuration_class
            event_subscriber_options[:integration_health] = integration_health
          end

          def default_configuration
            event_subscriber_options.fetch(:configuration_class).new
          end

          def event_subscriber_component
            event_subscriber_options.fetch(:component)
          end

          def event_subscriber_health
            event_subscriber_options.fetch(:integration_health)
          end

          private

          def event_subscriber_options
            @event_subscriber_options ||= {}
          end
        end

        def initialize(configuration = self.class.default_configuration)
          self.configuration = configuration
        end

        def configuration=(configuration)
          @configuration = configuration
          after_configuration_change
        end

        def emit(event)
          self.class.event_subscriber_health.with_failure_health(
            action: :emit,
            component: self.class.event_subscriber_component
          ) { emit_event(event) }
        end

        private

        def after_configuration_change = nil
      end
    end
  end
end
