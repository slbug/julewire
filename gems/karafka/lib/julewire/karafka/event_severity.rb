# frozen_string_literal: true

module Julewire
  module Karafka
    module EventSeverity
      FATAL_ERROR_TYPES = %w[
        runner.call.error
        swarm.supervisor.error
        worker.process.error
      ].freeze

      DEBUG_CONSUMER_EVENTS = %w[
        connection.listener.fetch_loop
        statistics.emitted
        swarm.manager.before_fork
        swarm.manager.control
      ].freeze

      ERROR_CONSUMER_EVENTS = %w[
        swarm.manager.stopping
        swarm.manager.terminating
      ].freeze

      DEBUG_PRODUCER_EVENTS = %w[
        oauthbearer.token_refresh
        statistics.emitted
      ].freeze

      class << self
        def consumer(name, event:, payload:)
          payload_severity(payload) || default_consumer_severity(name.to_s, event, payload)
        end

        def producer(name, payload)
          payload_severity(payload) || default_producer_severity(name.to_s)
        end

        def payload_severity(payload)
          value = payload_value(payload, :severity) || payload_value(payload, :level)
          Julewire::Core::Records::Severity.normalize(value) if value
        rescue StandardError
          nil
        end

        def default_consumer_severity(name, event, payload)
          return error_severity(event, payload) if name == "error.occurred"
          return fetch_loop_received_severity(event, payload) if name == "connection.listener.fetch_loop.received"
          return notice_signal_severity(event, payload) if name == "process.notice_signal"
          return :error if ERROR_CONSUMER_EVENTS.include?(name)
          return :debug if DEBUG_CONSUMER_EVENTS.include?(name)

          :info
        end

        def default_producer_severity(name)
          return :error if name == "error.occurred"
          return :debug if DEBUG_PRODUCER_EVENTS.include?(name)

          :info
        end

        def error_severity(event, payload)
          type = event_value(event, payload, :type).to_s
          FATAL_ERROR_TYPES.include?(type) ? :fatal : :error
        end

        def fetch_loop_received_severity(event, payload)
          messages = event_value(event, payload, :messages_buffer)
          count = collection_count(messages)

          count&.zero? ? :debug : :info
        end

        def notice_signal_severity(event, payload)
          signal = event_value(event, payload, :signal).to_s.upcase
          signal.end_with?("TTIN") ? :warn : :info
        end

        def event_value(event, payload, key)
          payload_value(payload, key) || raw_event_value(event, key)
        end

        def payload_value(payload, key)
          Core::Integration::Values::Read.value(payload, key)
        end

        def raw_event_value(event, key)
          raw = EventPayload.event_payload(event)
          return raw[key] if raw.respond_to?(:key?) && raw.key?(key)
          return raw[key.to_s] if raw.respond_to?(:key?) && raw.key?(key.to_s)
          return event[key] if event.respond_to?(:[])

          nil
        rescue StandardError
          nil
        end

        def collection_count(value)
          return value[:count] if value.is_a?(Hash) && value.key?(:count)
          return value["count"] if value.is_a?(Hash) && value.key?("count")
          return value.size if value.respond_to?(:size)

          nil
        end
      end
    end
  end
end
