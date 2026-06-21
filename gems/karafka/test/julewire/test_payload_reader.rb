# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestKarafkaPayloadReader < Minitest::Test
    include JulewireCapture

    cover Julewire::Karafka::PayloadReader

    RaisingReader = KarafkaTestSupport::RaisingReader
    Message = Data.define(:topic, :partition, :offset, :key, :headers)
    Group = Data.define(:id)
    Topic = Data.define(:name, :consumer_group, :subscription_group)
    Metadata = Data.define(:topic, :partition, :first_offset, :last_offset, :size, :processing_lag, :consumption_lag)

    def setup
      super
      reset_julewire!
    end

    def test_payload_reader_handles_hashes_methods_and_reader_failures
      message = { "topic" => "events", partition: 0, offset: 42, headers: { "h" => "v" } }
      consumer = { message: message }

      assert_equal(
        {
          consumer_class: "Hash",
          topic: "events",
          partition: 0,
          messages_count: 1,
          first_offset: 42,
          last_offset: 42
        },
        Julewire::Karafka::PayloadReader.consumer_payload(caller: consumer)
      )
      assert_equal [message], Julewire::Karafka::PayloadReader.messages_for(consumer)
      assert_equal({}, Julewire::Karafka::PayloadReader.headers(Object.new))
      assert_nil Julewire::Karafka::PayloadReader.value(RaisingReader.new, :topic)
    end

    def test_message_payload_reads_message_shape_and_defaults_headers
      message = Message.new("events", 0, 42, :customer, { "trace" => "1" })

      assert_equal(
        {
          topic: "events",
          partition: 0,
          offset: 42,
          key: :customer,
          headers: { "trace" => "1" }
        },
        Julewire::Karafka::PayloadReader.message_payload(message)
      )

      assert_equal(
        {
          headers: {}
        },
        Julewire::Karafka::PayloadReader.message_payload(Message.new(nil, nil, nil, nil, nil))
      )
    end

    def test_consumer_payload_without_consumer_is_empty
      assert_equal({}, Julewire::Karafka::PayloadReader.consumer_payload({}))
    end

    def test_consumer_payload_prefers_consumer_and_metadata_fields
      assert_equal(
        {
          consumer_class: "Hash",
          consumer_id: "consumer-1",
          consumer_group: "consumer-group",
          subscription_group: "subscription-group",
          topic: "consumer-topic",
          partition: 3,
          messages_count: 9,
          first_offset: 100,
          last_offset: 101,
          processing_lag_ms: 12,
          consumption_lag_ms: 13
        },
        Julewire::Karafka::PayloadReader.consumer_payload(caller: consumer_with_metadata)
      )
    end

    def test_consumer_payload_falls_back_to_metadata_and_message_fields
      metadata = Metadata.new("metadata-topic", 7, nil, nil, nil, nil, nil)
      messages = [Message.new("message-topic", 8, 200, nil, {})]
      messages.define_singleton_method(:metadata) { metadata }

      assert_equal(
        {
          consumer_class: "Hash",
          topic: "metadata-topic",
          partition: 7,
          messages_count: 1,
          first_offset: 200,
          last_offset: 200
        },
        Julewire::Karafka::PayloadReader.consumer_payload(caller: { messages: messages })
      )
    end

    def test_messages_for_uses_single_message_fallback
      message = Message.new("message-topic", 8, 200, nil, {})

      assert_equal [message], Julewire::Karafka::PayloadReader.messages_for(message: message)
      assert_equal ["scalar"], Julewire::Karafka::PayloadReader.messages_for(messages: "scalar")
      assert_empty Julewire::Karafka::PayloadReader.messages_for({})
    end

    def test_consumer_payload_matches_karafka_consumer_shape
      consumer = karafka_consumer(payloads: %w[first second], headers: { "trace" => "1" }, offsets: [41, 42])
      payload = Julewire::Karafka::PayloadReader.consumer_payload(caller: consumer)

      assert_equal "Julewire::KarafkaTestSupport::Consumer", payload.fetch(:consumer_class)
      assert_match(/\A[0-9a-f]{12}\z/, payload.fetch(:consumer_id))
      assert_equal "payments", payload.fetch(:consumer_group)
      assert_match(/\Apayments_[0-9a-f]+_0\z/, payload.fetch(:subscription_group))
      assert_equal "events", payload.fetch(:topic)
      assert_equal 0, payload.fetch(:partition)
      assert_equal 2, payload.fetch(:messages_count)
      assert_equal 41, payload.fetch(:first_offset)
      assert_equal 42, payload.fetch(:last_offset)
      assert_equal(-1, payload.fetch(:processing_lag_ms))
      assert_equal(-1, payload.fetch(:consumption_lag_ms))
    end

    private

    def consumer_with_metadata
      {
        id: "consumer-1",
        topic: Topic.new("consumer-topic", Group.new("consumer-group"), Group.new("subscription-group")),
        partition: 3,
        messages: messages_with_metadata
      }
    end

    def messages_with_metadata
      metadata = Metadata.new("metadata-topic", 7, 100, 101, 9, 12, 13)
      messages = [
        Message.new("message-topic", 8, 200, nil, {}),
        Message.new("message-topic", 8, 201, nil, {})
      ]
      messages.define_singleton_method(:metadata) { metadata }
      messages
    end
  end
end
