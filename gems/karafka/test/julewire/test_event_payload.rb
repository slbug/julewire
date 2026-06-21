# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestKarafkaEventPayload < Minitest::Test
    include JulewireCapture

    cover Julewire::Karafka::EventPayload

    BadHash = KarafkaTestSupport::BadHash
    FakeEvent = KarafkaTestSupport::FakeEvent
    RaisingPayload = KarafkaTestSupport::RaisingPayload
    class HashSubclass < Hash
    end
    NamedObject = Class.new do
      def name = "payload-name"
    end
    ConsumerErrorType = Class.new do
      def to_s = "consumer.consume.error"
    end

    def setup
      super
      reset_julewire!
    end

    def test_event_payload_handles_all_supported_shapes
      message = karafka_message(headers: { "trace" => "1" }, offsets: [42])
      values = Julewire::Karafka::EventPayload.call(
        "custom.event",
        caller: Object.new,
        message: message,
        messages: [message],
        exception: RuntimeError.new("boom"),
        time: Time.utc(2026, 1, 1),
        hash: { "a" => 1 },
        array: [1, 2],
        object: Object.new
      )

      assert_equal({ class: "Object" }, values.fetch(:caller))
      assert_equal "events", values.dig(:message, :topic)
      assert_equal({ count: 1 }, values.fetch(:messages))
      refute_includes values, :exception
      assert_equal "2026-01-01T00:00:00.000000000Z", values.fetch(:time)
      assert_equal({ a: 1 }, values.fetch(:hash))
      assert_equal({ count: 2 }, values.fetch(:array))
      assert_equal({ class: "Object" }, values.fetch(:object))
    end

    def test_event_payload_handles_primitive_values
      values = Julewire::Karafka::EventPayload.call(
        "custom.event",
        string: "value",
        symbol: :value,
        integer: 1,
        float: 1.5,
        true_value: true,
        false_value: false
      )

      assert_equal "value", values.fetch(:string)
      assert_equal :value, values.fetch(:symbol)
      assert_equal 1, values.fetch(:integer)
      assert_in_delta 1.5, values.fetch(:float)
      assert_same true, values.fetch(:true_value)
      assert_same false, values.fetch(:false_value)
    end

    def test_event_payload_normalizes_time_values_to_utc
      values = Julewire::Karafka::EventPayload.call(
        "custom.event",
        time: Time.new(2026, 1, 1, 1, 0, 0, "+01:00")
      )

      assert_equal "2026-01-01T00:00:00.000000000Z", values.fetch(:time)
    end

    def test_event_payload_skips_nil_safe_values
      assert_equal({}, Julewire::Karafka::EventPayload.call("custom.event", error: nil))
      assert_equal({}, Julewire::Karafka::EventPayload.call("custom.event", optional: nil))
    end

    def test_event_payload_extracts_error_for_core_error_shape
      error = RuntimeError.new("boom")

      assert_same error, Julewire::Karafka::EventPayload.error(error: error)
      assert_same error, Julewire::Karafka::EventPayload.error(exception: error)
      assert_same error, Julewire::Karafka::EventPayload.error(FakeEvent.new(error: error))
      assert_nil Julewire::Karafka::EventPayload.error(RaisingPayload.new)
    end

    def test_event_payload_enriches_consumer_batch_events
      consumer = karafka_consumer(payloads: %w[first second], headers: { "trace" => "1" }, offsets: [41, 42])
      event = ::Karafka::Core::Monitoring::Event.new(
        "consumer.consumed",
        { caller: consumer },
        0.123
      )

      values = Julewire::Karafka::EventPayload.call("consumer.consumed", event)

      assert_match(/\A[0-9a-f]{12}\z/, values.fetch(:consumer_id))
      assert_equal "payments", values.fetch(:consumer_group)
      assert_match(/\Apayments_[0-9a-f]+_0\z/, values.fetch(:subscription_group))
      assert_equal "events", values.fetch(:topic)
      assert_equal 0, values.fetch(:partition)
      assert_equal 2, values.fetch(:messages_count)
      assert_equal 41, values.fetch(:first_offset)
      assert_equal 42, values.fetch(:last_offset)
      assert_in_delta 0.123, values.fetch(:time)
      refute_includes values, :first_message_headers
    end

    def test_event_payload_accepts_symbol_consumer_event_names
      consumer = karafka_consumer(payloads: %w[first second], headers: { "trace" => "1" }, offsets: [41, 42])
      values = Julewire::Karafka::EventPayload.call(:"consumer.consumed", caller: consumer)

      assert_equal 2, values.fetch(:messages_count)
    end

    def test_event_payload_does_not_enrich_non_consumer_events
      consumer = karafka_consumer(payloads: %w[first second], headers: { "trace" => "1" }, offsets: [41, 42])
      values = Julewire::Karafka::EventPayload.call("custom.event", caller: consumer)

      assert_equal({ class: "Julewire::KarafkaTestSupport::Consumer" }, values.fetch(:caller))
      refute_includes values, :messages_count
    end

    def test_event_payload_does_not_enrich_non_consumer_event_types
      consumer = karafka_consumer(payloads: %w[first second], headers: { "trace" => "1" }, offsets: [41, 42])
      values = Julewire::Karafka::EventPayload.call(
        "custom.event",
        caller: consumer,
        type: "consumer.consume.error"
      )

      assert_equal "consumer.consume.error", values.fetch(:type)
      refute_includes values, :messages_count
    end

    def test_event_payload_enriches_consumer_errors
      consumer = karafka_consumer(payloads: %w[first second], headers: { "trace" => "1" }, offsets: [41, 42])
      values = Julewire::Karafka::EventPayload.call(
        "error.occurred",
        caller: consumer,
        type: "consumer.consume.error",
        error: RuntimeError.new("boom")
      )

      assert_match(/\A[0-9a-f]{12}\z/, values.fetch(:consumer_id))
      assert_equal "consumer.consume.error", values.fetch(:type)
      refute_includes values, :error
    end

    def test_event_payload_does_not_enrich_non_consumer_errors
      consumer = karafka_consumer(payloads: %w[first second], headers: { "trace" => "1" }, offsets: [41, 42])
      values = Julewire::Karafka::EventPayload.call(
        "error.occurred",
        caller: consumer,
        type: "worker.process.error",
        error: RuntimeError.new("boom")
      )

      assert_equal "worker.process.error", values.fetch(:type)
      refute_includes values, :messages_count
    end

    def test_event_payload_handles_string_payload_keys
      message = karafka_message(headers: { "trace" => "1" }, offsets: [42])
      values = Julewire::Karafka::EventPayload.call(
        "custom.event",
        "caller" => Object.new,
        "message" => message,
        "messages" => [message],
        "error" => RuntimeError.new("boom")
      )

      assert_equal({ class: "Object" }, values.fetch("caller"))
      assert_equal "events", values.dig("message", :topic)
      assert_equal({ count: 1 }, values.fetch("messages"))
      refute_includes values, "error"
    end

    def test_event_payload_hides_caller_values_as_class_only
      values = Julewire::Karafka::EventPayload.call("custom.event", caller: { secret: "nope" })

      assert_equal({ class: "Hash" }, values.fetch(:caller))
    end

    def test_event_payload_counts_scalar_messages
      values = Julewire::Karafka::EventPayload.call("custom.event", messages: Object.new)

      assert_equal({ count: 1 }, values.fetch(:messages))
    end

    def test_event_payload_counts_array_messages
      values = Julewire::Karafka::EventPayload.call("custom.event", messages: [Object.new, Object.new])

      assert_equal({ count: 2 }, values.fetch(:messages))
    end

    def test_event_payload_handles_to_h_events_non_hash_payloads_and_bad_values
      event = Object.new
      event.define_singleton_method(:to_h) { { bad: BadHash["a", 1] } }

      assert_equal({}, Julewire::Karafka::EventPayload.call("custom.event", "not hash"))
      assert_equal({}, Julewire::Karafka::EventPayload.call("custom.event", FakeEvent.new("not hash")))
      assert_equal(
        { bad: { class: "Julewire::KarafkaTestSupport::BadHash" } },
        Julewire::Karafka::EventPayload.call("custom.event", event)
      )
      assert_equal(
        { payload_error: { exception_class: "RuntimeError" } },
        Julewire::Karafka::EventPayload.call("custom.event", RaisingPayload.new)
      )
    end

    def test_event_payload_uses_class_name_for_named_objects
      values = Julewire::Karafka::EventPayload.call("custom.event", object: NamedObject.new)

      assert_equal({ class: "Julewire::TestKarafkaEventPayload::NamedObject" }, values.fetch(:object))
    end

    def test_event_payload_accepts_hash_subclasses
      payload = HashSubclass[topic: "events"]
      event = FakeEvent.new(HashSubclass[topic: "events"])

      assert_equal({ topic: "events" }, Julewire::Karafka::EventPayload.call("custom.event", payload))
      assert_equal({ topic: "events" }, Julewire::Karafka::EventPayload.call("custom.event", event))
    end

    def test_event_payload_enriches_consumer_error_symbol_types
      consumer = karafka_consumer(payloads: %w[first second], headers: { "trace" => "1" }, offsets: [41, 42])
      values = Julewire::Karafka::EventPayload.call(
        "error.occurred",
        caller: consumer,
        type: :"consumer.consume.error"
      )

      assert_equal 2, values.fetch(:messages_count)
    end

    def test_event_payload_enriches_consumer_error_stringable_types
      consumer = karafka_consumer(payloads: %w[first second], headers: { "trace" => "1" }, offsets: [41, 42])
      values = Julewire::Karafka::EventPayload.call(
        "error.occurred",
        caller: consumer,
        type: ConsumerErrorType.new
      )

      assert_equal 2, values.fetch(:messages_count)
    end
  end
end
