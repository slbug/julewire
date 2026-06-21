# frozen_string_literal: true

require "time"

module Julewire
  module Karafka
    module EventPayload
      CONSUMER_BATCH_EVENTS = %w[
        consumer.consume
        consumer.consumed
      ].freeze
      CONSUMER_ERROR_TYPE_PATTERN = /\Aconsumer\..*\.error\z/
      private_constant :CONSUMER_BATCH_EVENTS, :CONSUMER_ERROR_TYPE_PATTERN

      class << self
        def call(name, event)
          payload = event_payload(event)
          return {} unless payload.is_a?(Hash)

          payload.each_with_object(consumer_payload(name, payload)) do |(key, value), result|
            safe = safe_value(key, value)
            result[key] = safe unless safe.nil?
          end
        rescue StandardError => e
          { payload_error: { exception_class: e.class.name } }
        end

        def event_payload(event)
          return event.payload if event.respond_to?(:payload)

          event.to_h if event.respond_to?(:to_h)
        end

        def error(event)
          payload = event_payload(event)

          PayloadReader.value(payload, :error) || PayloadReader.value(payload, :exception)
        rescue StandardError
          nil
        end

        def consumer_payload(name, payload)
          return {} unless consumer_batch_event?(name, payload)

          PayloadReader.consumer_payload(payload)
        end

        def consumer_batch_event?(name, payload)
          event_name = name.to_s
          return true if CONSUMER_BATCH_EVENTS.include?(event_name)
          return false unless event_name == "error.occurred"

          type = PayloadReader.value(payload, :type).to_s
          type.match?(CONSUMER_ERROR_TYPE_PATTERN)
        end

        def safe_value(key, value)
          case key.to_sym
          when :caller
            { class: value.class.name }
          when :message
            PayloadReader.message_payload(value)
          when :messages
            { count: Array(value).size }
          when :error, :exception
            nil
          else
            primitive_value(value)
          end
        end

        def primitive_value(value)
          case value
          when nil, true, false, String, Symbol, Numeric
            value
          when Time
            value.utc.iso8601(9)
          when Hash
            value.transform_keys(&:to_sym)
          when Array
            { count: value.size }
          else
            { class: value.class.name }
          end
        rescue StandardError
          { class: value.class.name }
        end
      end
    end
  end
end
