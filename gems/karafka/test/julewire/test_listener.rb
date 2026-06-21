# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestKarafkaListener < Minitest::Test
    include JulewireCapture

    cover Julewire::Karafka::MonitorListener
    cover "Julewire::Karafka::MonitorSubscription"

    BasicMonitor = KarafkaTestSupport::BasicMonitor
    FakeEvent = KarafkaTestSupport::FakeEvent
    EventFlakyMonitor = KarafkaTestSupport::EventFlakyMonitor
    FakeMonitor = KarafkaTestSupport::FakeMonitor
    FlakyMonitor = KarafkaTestSupport::FlakyMonitor
    RaisingPayload = KarafkaTestSupport::RaisingPayload

    def setup
      super
      reset_julewire!
    end

    def test_listener_default_to_important_event_profile
      monitor = BasicMonitor.new

      install_consumer_listener(monitor)

      assert_includes monitor.subscriptions, "consumer.consumed"
      assert_includes monitor.subscriptions, "error.occurred"
      refute_includes monitor.subscriptions, "statistics.emitted"
    end

    def test_consumer_static_event_names_exist_in_karafka_catalog
      require "karafka/instrumentation/notifications"

      events = Julewire::Karafka::Configuration::IMPORTANT_CONSUMER_EVENT_NAMES +
               Julewire::Karafka::EventSeverity.const_get(:DEBUG_CONSUMER_EVENTS, false) +
               Julewire::Karafka::EventSeverity.const_get(:ERROR_CONSUMER_EVENTS, false) +
               Julewire::Karafka::EventPayload.const_get(:CONSUMER_BATCH_EVENTS, false) +
               Julewire::Karafka::ForkHooks.const_get(:EVENTS, false) +
               %w[
                 connection.listener.fetch_loop.received
                 process.notice_signal
               ]
      missing = events.uniq - ::Karafka::Instrumentation::Notifications::EVENTS

      assert_empty missing
    end

    def test_listener_subscribe_is_idempotent_and_updates_configuration
      records = capture_records
      monitor = FakeMonitor.new
      configuration = Julewire::Karafka::Configuration.new
      configuration.consumer_event_names = %w[one]
      next_configuration = Julewire::Karafka::Configuration.new
      next_configuration.consumer_event_names = %w[one two]
      next_configuration.source = "updated"

      install_consumer_listener(monitor, configuration: configuration)
      install_consumer_listener(monitor, configuration: next_configuration)
      monitor.publish("one", FakeEvent.new)
      narrow_configuration = Julewire::Karafka::Configuration.new
      narrow_configuration.consumer_event_names = %w[two]
      install_consumer_listener(monitor, configuration: narrow_configuration)

      assert_equal %w[two], profile_subscriptions(monitor)
      assert_equal "updated", records.fetch(0).fetch(:source)
    end

    def test_listener_can_subscribe_to_all_monitor_available_events
      assert_available_event_subscriptions(
        :consumer,
        setting: :consumer_event_names,
        events: %w[custom.consumer custom.error]
      )
    end

    def test_listener_can_subscribe_to_real_karafka_monitor_events
      monitor = ::Karafka::Instrumentation::Monitor.new

      subscribe_all_events(:consumer, monitor, :consumer_event_names)

      refute_empty monitor.listeners.fetch("consumer.consumed")
      refute_empty monitor.listeners.fetch("statistics.emitted")
    end

    def test_listener_can_subscribe_to_default_all_events_without_available_events
      monitor = BasicMonitor.new

      subscribe_all_events(:consumer, monitor, :consumer_event_names)

      assert_includes monitor.subscriptions, "consumer.consumed"
    end

    def test_listener_accepts_explicit_event_lists_and_ignores_bad_monitors
      configuration = Julewire::Karafka::Configuration.new
      configuration.consumer_event_names = %w[one two]
      monitor = FakeMonitor.new

      install_consumer_listener(monitor, configuration: configuration)

      assert_equal %w[one two], profile_subscriptions(monitor)
      bad_monitor = Object.new

      assert_same bad_monitor, install_consumer_listener(bad_monitor)
    end

    def test_listener_swallow_subscription_failures_without_retrying
      configuration = Julewire::Karafka::Configuration.new
      configuration.consumer_event_names = %w[retry]
      consumer_monitor = EventFlakyMonitor.new(ArgumentError.new("arity"), fail_events: %w[retry])

      install_consumer_listener(consumer_monitor, configuration: configuration)

      assert_empty profile_subscriptions(consumer_monitor)
      assert_equal :degraded, Julewire.health.dig(:process_integrations, :karafka, :status)
      assert_equal :listener, Julewire.health.dig(:process_integrations, :karafka, :last_failure, :component)
    end

    def test_listener_turns_monitor_events_into_records
      records = capture_records
      listener = consumer_listener

      listener.emit("error.occurred", FakeEvent.new(error: RuntimeError.new("boom")))

      record = records.fetch(0)

      assert_equal "karafka.error_occurred", record[:event]
      assert_equal :error, record[:severity]
      assert_equal "RuntimeError", record.dig(:error, :class)
      refute record.dig(:payload, :error)
      assert_karafka_source_contract(record, event: "karafka.error_occurred", logger: "Karafka.monitor")
    end

    def test_listener_enriches_real_karafka_consumer_success_timeline # rubocop:disable Metrics/AbcSize
      records = capture_records
      monitor = karafka_monitor("consumer.consume", "consumer.consumed", "error.occurred")
      configuration = Julewire::Karafka::Configuration.new
      configuration.consumer_event_names = %w[consumer.consume consumer.consumed error.occurred]
      install_consumer_listener(monitor, configuration: configuration)

      consumer = karafka_consumer(payloads: %w[first second], headers: { "trace" => "1" }, offsets: [41, 42])

      monitor.instrument("consumer.consume", caller: consumer)

      assert_equal :ok, monitor.instrument("consumer.consumed", caller: consumer) { :ok }

      consumed = records.find { it[:event] == "karafka.consumer_consumed" }
      events = records.map { it[:event] }

      assert_equal %w[karafka.consumer_consume karafka.consumer_consumed], events
      assert_equal :info, consumed[:severity]
      assert_match(/\A[0-9a-f]{12}\z/, consumed.dig(:attributes, :karafka, :consumer_id))
      assert_equal "payments", consumed.dig(:attributes, :karafka, :consumer_group)
      assert_equal 2, consumed.dig(:attributes, :karafka, :messages_count)
      assert_equal 41, consumed.dig(:attributes, :karafka, :first_offset)
      assert_equal 42, consumed.dig(:attributes, :karafka, :last_offset)
      assert_kind_of Numeric, consumed.dig(:attributes, :karafka, :time)
      assert_equal "kafka", consumed.dig(:neutral, :"messaging.system")
      assert_equal "events", consumed.dig(:neutral, :"messaging.destination.name")
      assert_equal 2, consumed.dig(:neutral, :"messaging.batch.message_count")
    end

    def test_listener_enriches_real_karafka_consumer_error_timeline
      records = capture_records
      monitor = karafka_monitor("consumer.consume", "consumer.consumed", "error.occurred")
      configuration = Julewire::Karafka::Configuration.new
      configuration.consumer_event_names = %w[consumer.consume consumer.consumed error.occurred]
      install_consumer_listener(monitor, configuration: configuration)

      consumer = karafka_consumer(payloads: %w[first second], headers: { "trace" => "1" }, offsets: [41, 42])
      error = assert_raises(RuntimeError) do
        monitor.instrument("consumer.consumed", caller: consumer) { raise "boom" }
      end
      monitor.instrument("error.occurred", caller: consumer, error: error, type: "consumer.consume.error")

      refute(records.any? { it[:event] == "karafka.consumer_consumed" })
      error_record = records.find { it[:event] == "karafka.error_occurred" }

      assert_equal :error, error_record[:severity]
      assert_equal "consumer.consume.error", error_record.dig(:attributes, :karafka, :type)
      assert_match(/\A[0-9a-f]{12}\z/, error_record.dig(:attributes, :karafka, :consumer_id))
      assert_equal 2, error_record.dig(:attributes, :karafka, :messages_count)
      assert_equal "RuntimeError", error_record.dig(:error, :class)
      refute error_record.dig(:attributes, :karafka, :error)
    end

    def test_listener_uses_monitor_payload_severity_when_present
      assert_equal(
        :debug,
        captured_severity(consumer_listener, "custom.event", FakeEvent.new(level: :debug))
      )
    end

    def test_listener_accepts_string_key_payload_severity
      assert_equal(
        :warn,
        captured_severity(consumer_listener, "custom.event", FakeEvent.new("level" => "warn"))
      )
    end

    def test_listener_contains_bad_events
      records = capture_records

      assert_nil consumer_listener.emit("custom.event", RaisingPayload.new)

      assert_equal "RuntimeError", records.fetch(0).dig(:attributes, :karafka, :payload_error, :exception_class)
    end

    def test_listener_records_adapter_failures
      listener = consumer_listener
      bad_name = Object.new

      _health, integration = assert_julewire_integration_failure_contract(
        integration: :karafka,
        component: :listener,
        exercise: -> { listener.emit(bad_name, FakeEvent.new) }
      )

      assert_equal :emit, integration.dig(:last_failure, :action)
      assert_equal "NoMethodError", integration.dig(:last_failure, :class)
    end

    def test_listener_contains_chaos_failures
      Julewire::Testing::Chaos.assert_emitter_chaos_contract(
        self,
        component: :karafka_listener,
        build: ->(_error) { consumer_listener },
        exercise: ->(listener, error) { listener.emit(raising_event_name(error), FakeEvent.new) }
      )
    end

    private

    def raising_event_name(error)
      Object.new.tap do |name|
        name.define_singleton_method(:to_s) { raise error }
      end
    end

    def karafka_monitor(*events)
      notifications = ::Karafka::Core::Monitoring::Notifications.new
      events.each { notifications.register_event(it) }
      ::Karafka::Core::Monitoring::Monitor.new(notifications)
    end
  end
end
