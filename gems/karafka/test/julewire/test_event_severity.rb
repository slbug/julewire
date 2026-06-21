# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestKarafkaEventSeverity < Minitest::Test
    include JulewireCapture

    cover Julewire::Karafka::EventSeverity

    FakeEvent = KarafkaTestSupport::FakeEvent
    class CountHash < Hash
    end
    SizeOnly = Data.define(:size)

    def setup
      super
      reset_julewire!
    end

    def test_listener_matches_karafka_debug_polling_severity
      records = capture_records
      listener = consumer_listener

      listener.emit("connection.listener.fetch_loop", FakeEvent.new)

      assert_equal :debug, records.fetch(0)[:severity]
    end

    def test_listener_matches_karafka_fetch_received_zero_messages_severity
      records = capture_records
      listener = consumer_listener

      listener.emit("connection.listener.fetch_loop.received", FakeEvent.new(messages_buffer: []))
      listener.emit("connection.listener.fetch_loop.received", FakeEvent.new(messages_buffer: [Object.new]))

      assert_equal :debug, records.fetch(0)[:severity]
      assert_equal :info, records.fetch(1)[:severity]
    end

    def test_consumer_severity_uses_payload_overrides
      assert_equal :warn, Julewire::Karafka::EventSeverity.consumer(
        "custom.event",
        event: FakeEvent.new,
        payload: { severity: :warn }
      )
      assert_equal :debug, Julewire::Karafka::EventSeverity.consumer(
        "custom.event",
        event: FakeEvent.new,
        payload: { "level" => "debug" }
      )
    end

    def test_producer_severity_uses_payload_overrides_and_defaults
      assert_equal :warn, Julewire::Karafka::EventSeverity.producer("custom.event", severity: :warn)
      assert_equal :debug, Julewire::Karafka::EventSeverity.producer("custom.event", "level" => "debug")
      assert_equal :error, Julewire::Karafka::EventSeverity.producer("error.occurred", {})
      assert_equal :debug, Julewire::Karafka::EventSeverity.producer("statistics.emitted", {})
      assert_equal :debug, Julewire::Karafka::EventSeverity.producer("oauthbearer.token_refresh", {})
      assert_equal :info, Julewire::Karafka::EventSeverity.producer("message.produced_sync", {})
    end

    def test_listener_matches_karafka_fatal_error_types
      %w[
        runner.call.error
        swarm.supervisor.error
        worker.process.error
      ].each do |type|
        assert_equal(
          :fatal,
          captured_severity(
            consumer_listener,
            "error.occurred",
            FakeEvent.new(type: type, error: RuntimeError.new("boom"))
          )
        )
      end
    end

    def test_listener_matches_karafka_signal_warning
      assert_equal(
        :warn,
        captured_severity(consumer_listener, "process.notice_signal", FakeEvent.new(signal: :SIGTTIN))
      )
    end

    def test_listener_matches_all_static_consumer_severity_buckets
      records = capture_records
      listener = consumer_listener

      %w[
        swarm.manager.stopping
        swarm.manager.terminating
      ].each { listener.emit(it, FakeEvent.new) }
      %w[
        connection.listener.fetch_loop
        statistics.emitted
        swarm.manager.before_fork
        swarm.manager.control
      ].each { listener.emit(it, FakeEvent.new) }
      severities = records.map { it[:severity] }

      assert_equal %i[error error debug debug debug debug], severities
    end

    def test_listener_matches_additional_default_severities
      records = capture_records
      listener = consumer_listener

      listener.emit("swarm.manager.stopping", FakeEvent.new)
      listener.emit("process.notice_signal", FakeEvent.new(signal: :TERM))
      listener.emit("custom.event", FakeEvent.new)
      listener.emit("connection.listener.fetch_loop.received", FakeEvent.new(messages_buffer: { count: 0 }))
      listener.emit("connection.listener.fetch_loop.received", FakeEvent.new(messages_buffer: { "count" => 1 }))

      assert_equal(%i[error info info debug info], records.last(5).map { it[:severity] })
    end

    def test_fetch_received_severity_counts_hash_subclasses_and_size_objects
      assert_equal :debug, Julewire::Karafka::EventSeverity.consumer(
        "connection.listener.fetch_loop.received",
        event: FakeEvent.new,
        payload: { messages_buffer: CountHash[count: 0] }
      )
      assert_equal :info, Julewire::Karafka::EventSeverity.consumer(
        "connection.listener.fetch_loop.received",
        event: FakeEvent.new,
        payload: { messages_buffer: SizeOnly.new(1) }
      )
    end

    def test_event_severity_handles_payload_and_event_edge_cases
      event = Object.new
      event.define_singleton_method(:[]) { |_key| "worker.process.error" }

      assert_nil Julewire::Karafka::EventSeverity.payload_severity(Object.new)
      assert_equal :fatal, Julewire::Karafka::EventSeverity.consumer("error.occurred", event: event, payload: {})
      assert_nil Julewire::Karafka::EventSeverity.collection_count(Object.new)
      assert_equal :info, Julewire::Karafka::EventSeverity.consumer(
        "connection.listener.fetch_loop.received",
        event: Object.new,
        payload: {}
      )

      bad_event = Object.new
      bad_event.define_singleton_method(:[]) { |_key| raise "bad event" }

      assert_nil Julewire::Karafka::EventSeverity.raw_event_value(bad_event, :type)
    end
  end
end
