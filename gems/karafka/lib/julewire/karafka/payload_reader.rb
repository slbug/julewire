# frozen_string_literal: true

module Julewire
  module Karafka
    module PayloadReader
      class << self
        def consumer_payload(payload)
          consumer = value(payload, :caller)
          message_set = value(consumer, :messages)
          metadata = value(message_set, :metadata)
          messages = messages_for(consumer)
          first = messages.first
          last = messages.last

          {
            consumer_class: consumer&.class&.name,
            consumer_id: value(consumer, :id),
            consumer_group: nested_value(consumer, :topic, :consumer_group, :id),
            subscription_group: nested_value(consumer, :topic, :subscription_group, :id),
            topic: consumer_topic(consumer, metadata, first),
            partition: consumer_partition(consumer, metadata, first),
            messages_count: count(messages, metadata),
            first_offset: value(metadata, :first_offset) || value(first, :offset),
            last_offset: value(metadata, :last_offset) || value(last, :offset),
            processing_lag_ms: value(metadata, :processing_lag),
            consumption_lag_ms: value(metadata, :consumption_lag)
          }.compact
        end

        def message_payload(message)
          {
            topic: value(message, :topic),
            partition: value(message, :partition),
            offset: value(message, :offset),
            key: value(message, :key),
            headers: headers(message)
          }.compact
        end

        def messages_for(consumer)
          messages = value(consumer, :messages)
          return Array(messages) if messages

          message = value(consumer, :message)
          message ? [message] : []
        end

        def headers(message)
          value(message, :headers) || {}
        end

        def count(messages, metadata)
          value(metadata, :size) || messages.size.nonzero?
        end

        def consumer_topic(consumer, metadata, first)
          nested_value(consumer, :topic, :name) || value(metadata, :topic) || value(first, :topic)
        end

        def consumer_partition(consumer, metadata, first)
          value(consumer, :partition) || value(metadata, :partition) || value(first, :partition)
        end

        def nested_value(object, *method_names)
          Core::Integration::Values::Read.nested_value(object, *method_names)
        end

        def value(object, method_name)
          Core::Integration::Values::Read.value(object, method_name)
        end
      end
    end
  end
end
