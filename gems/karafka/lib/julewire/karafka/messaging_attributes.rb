# frozen_string_literal: true

module Julewire
  module Karafka
    module MessagingAttributes
      class << self
        def message(fields)
          Core::Fields::AttributeKeys.fields(
            Core::Fields::AttributeKeys::MESSAGING_SYSTEM => "kafka",
            Core::Fields::AttributeKeys::MESSAGING_OPERATION_NAME => "process",
            Core::Fields::AttributeKeys::MESSAGING_OPERATION_TYPE => "process",
            Core::Fields::AttributeKeys::MESSAGING_DESTINATION_NAME => fields[:topic],
            Core::Fields::AttributeKeys::MESSAGING_DESTINATION_PARTITION_ID => string_value(fields[:partition]),
            Core::Fields::AttributeKeys::MESSAGING_KAFKA_OFFSET => string_value(fields[:offset]),
            Core::Fields::AttributeKeys::MESSAGING_KAFKA_MESSAGE_KEY => string_value(fields[:key])
          )
        end

        def monitor(name, payload, role:)
          Core::Fields::AttributeKeys.fields(
            Core::Fields::AttributeKeys::MESSAGING_SYSTEM => "kafka",
            Core::Fields::AttributeKeys::MESSAGING_OPERATION_NAME => name.to_s,
            Core::Fields::AttributeKeys::MESSAGING_OPERATION_TYPE => operation_type(name, role: role),
            Core::Fields::AttributeKeys::MESSAGING_DESTINATION_NAME => payload[:topic] || payload.dig(:message, :topic),
            Core::Fields::AttributeKeys::MESSAGING_DESTINATION_PARTITION_ID => string_value(
              payload[:partition] || payload.dig(:message, :partition)
            ),
            Core::Fields::AttributeKeys::MESSAGING_BATCH_MESSAGE_COUNT => message_count(payload),
            Core::Fields::AttributeKeys::MESSAGING_CONSUMER_GROUP_NAME => payload[:consumer_group],
            Core::Fields::AttributeKeys::MESSAGING_KAFKA_OFFSET => string_value(first_offset(payload))
          )
        end

        private

        def message_count(payload)
          payload[:messages_count] || payload.dig(:messages, :count)
        end

        def first_offset(payload)
          payload[:first_offset] || payload.dig(:message, :offset)
        end

        def operation_type(name, role:)
          return "send" if role == :producer

          "receive" if name.to_s.include?("consume")
        end

        def string_value(value)
          value&.to_s
        end
      end
    end
  end
end
