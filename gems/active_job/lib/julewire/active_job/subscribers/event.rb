# frozen_string_literal: true

module Julewire
  module ActiveJob
    module Subscribers
      class Event
        include Core::Integration::EventSubscriber

        STRUCTURED_EVENT_FILE = "active_job/structured_event_subscriber"
        ERROR_EVENTS = %w[
          active_job.retry_stopped
          active_job.discarded
        ].freeze

        event_subscriber integration_health: IntegrationHealth, configuration_class: Configuration

        class << self
          include Core::Integration::SubscriberInstall

          def install!(configuration, event_reporter: nil)
            return reset! unless configuration.structured_events?

            Core::Integration::Lifecycle.require_optional(STRUCTURED_EVENT_FILE)
            reporter = event_reporter || Julewire::RailsSupport::EventReporter.default
            return unless Julewire::RailsSupport::EventReporter.subscribable?(reporter)

            install_subscriber(configuration, enabled: true) do |subscriber|
              Julewire::RailsSupport::EventReporter.subscribe(reporter, subscriber) { subscriber.accept?(it) }
            end
          end
        end

        def accept?(event)
          return false unless @configuration.structured_events?

          prefixes = @configuration.event_prefixes
          return true if prefixes.nil?

          name = event[:name].to_s
          Array(prefixes).any? { name.start_with?(it.to_s) }
        end

        private

        def emit_event(event)
          name = event[:name].to_s
          record = record_for(event, name)
          enrich_continuation_summary(name, record.dig(:attributes, :active_job) || {})
          Core::Integration::Facade.emit(record)
        end

        def record_for(event, name)
          values = Core::Integration::Values::Shape
          payload = values.payload_hash(event[:payload])
          record = base_record(event, name, payload)
          record[:error] = error_payload(payload) if exception_payload?(payload)
          record
        end

        def base_record(event, name, payload)
          values = Core::Integration::Values::Shape
          record = {
            severity: severity_for(name, payload),
            event: name,
            logger: "ActiveJob.event",
            context: values.hash_or_empty(event[:context]),
            attributes: attributes_for(event, payload),
            neutral: neutral_for(event, payload)
          }
          values.append_field(record, :timestamp, values.timestamp(event[:timestamp]))
          values.append_field(record, :source, @configuration.source)
          record
        end

        def attributes_for(event, payload)
          values = Core::Integration::Values::Shape
          active_job = payload.empty? ? {} : payload
          values.append_compact_field(active_job, :tags, values.hash_or_empty(event[:tags]))
          { active_job: active_job }
        end

        def neutral_for(event, payload)
          values = Core::Integration::Values::Shape
          Core::Fields::FieldSet.merge!(
            JobAttributes.call(payload),
            values.source_location_attributes(event[:source_location])
          )
        end

        def severity_for(name, payload)
          return :error if ERROR_EVENTS.include?(name)
          return :error if exception_payload?(payload)

          :info
        end

        def exception_payload?(payload)
          return false unless payload.is_a?(Hash)

          payload.key?(:exception_class) ||
            payload.key?(:exception_message) ||
            payload.key?(:exception_backtrace)
        end

        def error_payload(payload)
          {
            class: payload[:exception_class],
            message: payload[:exception_message],
            backtrace: payload[:exception_backtrace]
          }.compact
        end

        def enrich_continuation_summary(name, payload)
          return unless Core::Integration::Facade.summary_active?

          case name
          when "active_job.step_started"
            increment_summary(:continuation_steps_started)
            add_step_summary(payload, state: "started")
          when "active_job.step"
            enrich_completed_step_summary(payload)
          when "active_job.step_skipped"
            increment_summary(:continuation_steps_skipped)
            add_step_summary(payload, state: "skipped")
          when "active_job.interrupt"
            enrich_interrupt_summary(payload)
          when "active_job.resume"
            enrich_resume_summary(payload)
          end
        rescue StandardError
          nil
        end

        def enrich_interrupt_summary(payload)
          increment_summary(:continuation_interruptions)
          Core::Integration::Facade.add_summary_attributes(
            active_job: {
              continuation_status: "interrupted",
              continuation_description: payload[:description],
              continuation_interrupt_reason: payload[:reason]
            }
          )
        end

        def enrich_resume_summary(payload)
          increment_summary(:continuation_resumptions)
          Core::Integration::Facade.add_summary_attributes(
            active_job: {
              continuation_status: "resumed",
              continuation_description: payload[:description]
            }
          )
        end

        def enrich_completed_step_summary(payload)
          if payload[:interrupted]
            increment_summary(:continuation_steps_interrupted)
            add_step_summary(payload, state: "interrupted")
          elsif exception_payload?(payload)
            increment_summary(:continuation_steps_failed)
            add_step_summary(payload, state: "failed")
          else
            increment_summary(:continuation_steps_completed)
            add_step_summary(payload, state: "completed")
          end
        end

        def add_step_summary(payload, state:)
          Core::Integration::Facade.add_summary_attributes(
            active_job: {
              continuation_last_step: payload[:step],
              continuation_last_step_cursor: payload[:cursor],
              continuation_last_step_state: state,
              continuation_last_step_resumed: payload[:resumed]
            }
          )
        end

        def increment_summary(key)
          Core::Integration::Facade.increment_summary_attribute(:active_job, key)
        end
      end
    end
  end
end
