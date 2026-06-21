# frozen_string_literal: true

module Julewire
  module Karafka
    class MonitorListener
      Profile = Data.define(
        :component,
        :event_prefix,
        :logger_name,
        :messaging_role,
        :config_method,
        :important_events,
        :severity
      )

      CONSUMER_PROFILE = Profile.new(
        component: :listener,
        event_prefix: "karafka",
        logger_name: "Karafka.monitor",
        messaging_role: :consumer,
        config_method: :consumer_event_names,
        important_events: Configuration::IMPORTANT_CONSUMER_EVENT_NAMES,
        severity: ->(name, event, payload) { EventSeverity.consumer(name, event: event, payload: payload) }
      ).freeze
      PRODUCER_PROFILE = Profile.new(
        component: :waterdrop_listener,
        event_prefix: "waterdrop",
        logger_name: "WaterDrop.monitor",
        messaging_role: :producer,
        config_method: :producer_event_names,
        important_events: Configuration::IMPORTANT_PRODUCER_EVENT_NAMES,
        severity: ->(name, _event, payload) { EventSeverity.producer(name, payload) }
      ).freeze
      private_constant :Profile, :CONSUMER_PROFILE, :PRODUCER_PROFILE

      class << self
        def consumer(configuration = Configuration.new)
          new(configuration, profile: CONSUMER_PROFILE)
        end

        def producer(configuration = Configuration.new)
          new(configuration, profile: PRODUCER_PROFILE)
        end
      end

      def initialize(configuration = Configuration.new, profile:)
        @configuration = configuration
        @profile = profile
      end

      attr_writer :configuration

      def emit(name, event)
        IntegrationHealth.with_failure_health(
          action: :emit,
          component: @profile.component,
          event: name
        ) do
          payload = EventPayload.call(name, event)
          Core::Integration::Facade.emit(
            severity: @profile.severity.call(name, event, payload),
            event: "#{@profile.event_prefix}.#{name.tr(".", "_")}",
            logger: @profile.logger_name,
            source: @configuration.source,
            error: EventPayload.error(event),
            neutral: messaging_attributes(name, payload),
            attributes: event_attributes(name, payload)
          )
        end
        nil
      end

      def event_attributes(_name, payload)
        Core.deep_compact_empty(@profile.event_prefix.to_sym => payload)
      end

      def messaging_attributes(name, payload)
        MessagingAttributes.monitor(name, payload, role: @profile.messaging_role)
      end
    end
  end
end
