# frozen_string_literal: true

module Julewire
  module Rails
    module Subscribers
      class Event
        include Core::Integration::EventSubscriber

        STRUCTURED_EVENT_FILES = %w[
          action_controller/structured_event_subscriber
          action_dispatch/structured_event_subscriber
          action_view/structured_event_subscriber
          active_record/structured_event_subscriber
        ].freeze

        REQUEST_STARTED = "action_controller.request_started"
        REQUEST_COMPLETED = "action_controller.request_completed"
        REQUEST_CONTEXT_KEYS = %i[controller action format].freeze

        event_subscriber integration_health: IntegrationHealth, configuration_class: Configuration

        class << self
          include Core::Integration::SubscriberInstall

          def install!(configuration)
            return reset! unless configuration.structured_events?

            require_structured_event_subscribers
            reporter = Julewire::RailsSupport::EventReporter.default
            return unless Julewire::RailsSupport::EventReporter.subscribable?(reporter)

            install_subscriber(configuration, enabled: true) do |subscriber|
              Julewire::RailsSupport::EventReporter.subscribe(reporter, subscriber) do |event|
                subscriber.accept?(event)
              end
            end
          end

          private

          def require_structured_event_subscribers
            STRUCTURED_EVENT_FILES.each { Core::Integration::Lifecycle.require_optional(it) }
          end
        end

        def accept?(event)
          return false unless @configuration.structured_events?
          return false if Suppression.active?

          name = event[:name].to_s
          return false if excluded_event?(name)

          included_event?(name)
        end

        private

        def emit_event(event)
          name = event[:name].to_s
          payload = event_record.payload_hash(event[:payload])

          if name == REQUEST_STARTED && current_execution?
            enrich_request_start(payload)
          elsif name == REQUEST_COMPLETED && current_execution?
            enrich_request_completion(payload)
          else
            Core::Integration::Facade.emit(event_record.call(event, name: name, payload: payload))
          end
        end

        def after_configuration_change
          @event_record = nil
        end

        def current_execution?
          Julewire.current_execution?
        end

        def included_event?(name)
          names = @configuration.structured_event_names
          prefixes = @configuration.structured_event_prefixes
          return true if prefixes.nil?
          return true if Array(names).any? { name == it.to_s }

          Array(prefixes).any? { name.start_with?(it.to_s) }
        end

        def excluded_event?(name)
          Array(@configuration.structured_event_exclude_names).any? { name == it.to_s } ||
            Array(@configuration.structured_event_exclude_prefixes).any? { name.start_with?(it.to_s) }
        end

        def enrich_request_start(payload)
          fields = payload.slice(*REQUEST_CONTEXT_KEYS, :params).compact
          add_summary_attributes(rails: fields)
        end

        def enrich_request_completion(payload)
          add_summary_attributes(rails: request_completion_fields(payload))
        end

        def add_summary_attributes(fields)
          Core::Integration::Facade.add_summary_attributes(fields)
        end

        def request_completion_fields(payload)
          return payload unless payload.key?(:duration_ms)

          payload.merge(action_runtime_ms: payload[:duration_ms]).except(:duration_ms)
        end

        def event_record
          @event_record ||= StructuredEventRecord.new(@configuration)
        end
      end
    end
  end
end
