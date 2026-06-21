# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestKarafkaMessagingAttributes < Minitest::Test
    cover Julewire::Karafka::MessagingAttributes

    def test_message_maps_message_fields_to_neutral_attributes
      fields = {
        topic: "events",
        partition: 2,
        offset: 42,
        key: :customer
      }

      attributes = Julewire::Karafka::MessagingAttributes.message(fields)

      assert_equal(
        {
          "messaging.system": "kafka",
          "messaging.operation.name": "process",
          "messaging.operation.type": "process",
          "messaging.destination.name": "events",
          "messaging.destination.partition.id": "2",
          "messaging.kafka.offset": "42",
          "messaging.kafka.message.key": "customer"
        },
        attributes
      )
    end

    def test_message_omits_nil_optional_attributes
      attributes = Julewire::Karafka::MessagingAttributes.message(topic: "events")

      assert_equal(
        {
          "messaging.system": "kafka",
          "messaging.operation.name": "process",
          "messaging.operation.type": "process",
          "messaging.destination.name": "events"
        },
        attributes
      )
    end

    def test_message_omits_missing_destination_fields
      attributes = Julewire::Karafka::MessagingAttributes.message({})

      assert_equal(
        {
          "messaging.system": "kafka",
          "messaging.operation.name": "process",
          "messaging.operation.type": "process"
        },
        attributes
      )
    end

    def test_consumer_monitor_maps_top_level_payload
      payload = {
        topic: "events",
        partition: 2,
        messages_count: 3,
        consumer_group: "payments",
        first_offset: 42
      }

      attributes = Julewire::Karafka::MessagingAttributes.monitor("consumer.consumed", payload, role: :consumer)

      assert_equal(
        {
          "messaging.system": "kafka",
          "messaging.operation.name": "consumer.consumed",
          "messaging.operation.type": "receive",
          "messaging.destination.name": "events",
          "messaging.destination.partition.id": "2",
          "messaging.batch.message_count": 3,
          "messaging.consumer.group.name": "payments",
          "messaging.kafka.offset": "42"
        },
        attributes
      )
    end

    def test_monitor_falls_back_to_nested_message_and_messages_count
      payload = {
        message: {
          topic: "events",
          partition: 2,
          offset: 42
        },
        messages: {
          count: 3
        }
      }

      attributes = Julewire::Karafka::MessagingAttributes.monitor(:worker_completed, payload, role: :consumer)

      assert_equal "events", attributes[:"messaging.destination.name"]
      assert_equal "2", attributes[:"messaging.destination.partition.id"]
      assert_equal 3, attributes[:"messaging.batch.message_count"]
      assert_equal "42", attributes[:"messaging.kafka.offset"]
      refute attributes.key?(:"messaging.operation.type")
      refute attributes.key?(:"messaging.consumer.group.name")
    end

    def test_producer_monitor_uses_send_operation
      attributes = Julewire::Karafka::MessagingAttributes.monitor(:message_produced, {}, role: :producer)

      assert_equal "message_produced", attributes[:"messaging.operation.name"]
      assert_equal "send", attributes[:"messaging.operation.type"]
      assert_equal "kafka", attributes[:"messaging.system"]
    end
  end
end
