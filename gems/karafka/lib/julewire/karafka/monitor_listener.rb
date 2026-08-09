# frozen_string_literal: true

module Julewire
  module Karafka
    class MonitorListener
      class << self
        def consumer(configuration = Configuration.new)
          new(configuration, profile: MonitorProfiles.consumer)
        end

        def producer(configuration = Configuration.new)
          new(configuration, profile: MonitorProfiles.producer)
        end
      end

      def initialize(configuration, profile:)
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
            attributes: event_attributes(payload)
          )
        end
      end

      def event_attributes(payload)
        Core.deep_compact_empty(@profile.event_prefix.to_sym => payload)
      end

      def messaging_attributes(name, payload)
        MessagingAttributes.monitor(name, payload, role: @profile.messaging_role)
      end
    end
  end
end
