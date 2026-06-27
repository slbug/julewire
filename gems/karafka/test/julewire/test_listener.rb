# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestKarafkaListener < Minitest::Test
    cover "Julewire::Karafka::EventSeverity.error_severity"
    cover "Julewire::Karafka::Installer.install!"
    cover Julewire::Karafka::MonitorListener
    cover "Julewire::Karafka::MonitorSubscription*"
    cover "Julewire::Karafka::MonitorListener#messaging_attributes"
    cover "Julewire::Karafka::MonitorListener.producer"
    include JulewireCapture

    BasicMonitor = KarafkaTestSupport::BasicMonitor
    FakeEvent = KarafkaTestSupport::FakeEvent
    EventFlakyMonitor = KarafkaTestSupport::EventFlakyMonitor
    FakeMonitor = KarafkaTestSupport::FakeMonitor
    FlakyMonitor = KarafkaTestSupport::FlakyMonitor
    RaisingPayload = KarafkaTestSupport::RaisingPayload
    class HashSubclass < Hash
    end

    SignalPayload = Data.define(:signal)

    class NotificationBusMonitor < BasicMonitor
      def notifications_bus
        Data.define(:available_events).new(%w[bus.one bus.two])
      end
    end

    class ListenerHashMonitor < BasicMonitor
      def listeners
        HashSubclass["listener.one" => [], "listener.two" => []]
      end
    end

    class ListenerKeysObjectMonitor < BasicMonitor
      def listeners
        Object.new.tap do |object|
          object.define_singleton_method(:keys) { %w[not.a.listener.catalog] }
        end
      end
    end

    class UnsubscribeFlakyMonitor < FakeMonitor
      def unsubscribe(_listener_or_block)
        raise "unsubscribe failed"
      end
    end

    class NoSubscribeMonitor
      attr_reader :unsubscribe_count

      def initialize
        @unsubscribe_count = 0
      end

      def unsubscribe(_callback)
        @unsubscribe_count += 1
      end
    end

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
      monitor.publish("two", FakeEvent.new)
      narrow_configuration = Julewire::Karafka::Configuration.new
      narrow_configuration.consumer_event_names = %w[two]
      install_consumer_listener(monitor, configuration: narrow_configuration)

      assert_equal %w[two], profile_subscriptions(monitor)
      assert_equal(%w[updated updated], records.map { it.fetch(:source) })
    end

    def test_listener_uses_initial_configuration
      records = capture_records
      monitor = FakeMonitor.new
      configuration = Julewire::Karafka::Configuration.new
      configuration.consumer_event_names = %w[one]
      configuration.source = "initial"

      install_consumer_listener(monitor, configuration: configuration)
      monitor.publish("one", FakeEvent.new)

      assert_equal(["initial"], records.map { it.fetch(:source) })
    end

    def test_listener_class_helpers_use_supplied_configuration
      records = capture_records
      consumer_configuration = Julewire::Karafka::Configuration.new
      consumer_configuration.source = "direct-consumer"
      producer_configuration = Julewire::Karafka::Configuration.new
      producer_configuration.source = "direct-producer"

      Julewire::Karafka::MonitorListener.consumer(consumer_configuration).emit("consumer.consumed", FakeEvent.new)
      Julewire::Karafka::MonitorListener.producer(producer_configuration).emit("message.produced_sync", FakeEvent.new)

      assert_equal(%w[direct-consumer direct-producer], records.map { it.fetch(:source) })
      assert_equal "send", records.fetch(1).dig(:neutral, :"messaging.operation.type")
    end

    def test_producer_class_helper_accepts_default_configuration
      records = capture_records

      Julewire::Karafka::MonitorListener.producer.emit("message.produced_sync", FakeEvent.new)

      record = records.fetch(0)

      assert_equal "karafka", record.fetch(:source)
      assert_equal "send", record.dig(:neutral, :"messaging.operation.type")
    end

    def test_listener_can_subscribe_to_all_monitor_available_events
      assert_available_event_subscriptions(
        :consumer,
        setting: :consumer_event_names,
        events: %w[custom.consumer custom.error]
      )
    end

    def test_listener_can_subscribe_to_available_selector
      monitor = FakeMonitor.new(%w[available.consumer])
      configuration = Julewire::Karafka::Configuration.new
      configuration.consumer_event_names = :available

      install_consumer_listener(monitor, configuration: configuration)

      assert_equal %w[available.consumer], profile_subscriptions(monitor)
    end

    def test_listener_uses_notification_bus_and_listener_hash_discovery
      bus_monitor = NotificationBusMonitor.new
      listener_monitor = ListenerHashMonitor.new

      subscribe_all_events(:consumer, bus_monitor, :consumer_event_names)
      subscribe_all_events(:consumer, listener_monitor, :consumer_event_names)

      assert_equal %w[bus.one bus.two], profile_subscriptions(bus_monitor)
      assert_equal %w[listener.one listener.two], profile_subscriptions(listener_monitor)
    end

    def test_listener_ignores_non_hash_listener_catalogs
      monitor = ListenerKeysObjectMonitor.new

      subscribe_all_events(:consumer, monitor, :consumer_event_names)

      assert_includes profile_subscriptions(monitor), "consumer.consumed"
      refute_includes profile_subscriptions(monitor), "not.a.listener.catalog"
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
      assert_nil Julewire.health.dig(:process_integrations, :karafka, :last_failure)
    end

    def test_listener_accepts_scalar_event_name
      configuration = Julewire::Karafka::Configuration.new
      configuration.consumer_event_names = "one"
      monitor = FakeMonitor.new

      install_consumer_listener(monitor, configuration: configuration)

      assert_equal %w[one], profile_subscriptions(monitor)
    end

    def test_listener_records_unsubscribe_failures
      monitor = UnsubscribeFlakyMonitor.new
      configuration = Julewire::Karafka::Configuration.new
      configuration.consumer_event_names = %w[one]
      next_configuration = Julewire::Karafka::Configuration.new
      next_configuration.consumer_event_names = %w[two]

      install_consumer_listener(monitor, configuration: configuration)
      install_consumer_listener(monitor, configuration: next_configuration)

      failure = Julewire.health.dig(:process_integrations, :karafka, :last_failure)

      assert_equal :unsubscribe, failure.fetch(:action)
      assert_equal :listener, failure.fetch(:component)
      assert_equal "one", failure.fetch(:event)
    end

    def test_listener_unsubscribes_removed_events_after_retained_events
      monitor = FakeMonitor.new
      configuration = Julewire::Karafka::Configuration.new
      configuration.consumer_event_names = %w[one two]
      next_configuration = Julewire::Karafka::Configuration.new
      next_configuration.consumer_event_names = %w[one]

      install_consumer_listener(monitor, configuration: configuration)
      install_consumer_listener(monitor, configuration: next_configuration)

      assert_equal %w[one], profile_subscriptions(monitor)
    end

    def test_listener_does_not_unsubscribe_retained_events
      monitor = UnsubscribeFlakyMonitor.new
      configuration = Julewire::Karafka::Configuration.new
      configuration.consumer_event_names = %w[one]

      install_consumer_listener(monitor, configuration: configuration)
      install_consumer_listener(monitor, configuration: configuration)

      assert_nil Julewire.health.dig(:process_integrations, :karafka, :last_failure)
    end

    def test_listener_skips_unsubscribe_when_monitor_cannot_unsubscribe
      monitor = BasicMonitor.new
      configuration = Julewire::Karafka::Configuration.new
      configuration.consumer_event_names = %w[one]
      next_configuration = Julewire::Karafka::Configuration.new
      next_configuration.consumer_event_names = %w[two]

      install_consumer_listener(monitor, configuration: configuration)
      install_consumer_listener(monitor, configuration: next_configuration)

      assert_nil Julewire.health.dig(:process_integrations, :karafka, :last_failure)
    end

    def test_listener_does_not_store_fake_subscriptions_for_monitors_without_subscribe
      monitor = NoSubscribeMonitor.new
      configuration = Julewire::Karafka::Configuration.new
      configuration.consumer_event_names = %w[one]
      next_configuration = Julewire::Karafka::Configuration.new
      next_configuration.consumer_event_names = []

      install_consumer_listener(monitor, configuration: configuration)
      install_consumer_listener(monitor, configuration: next_configuration)

      assert_equal 0, monitor.unsubscribe_count
      assert_nil Julewire.health.dig(:process_integrations, :karafka, :last_failure)
    end

    def test_listener_keeps_consumer_and_producer_state_isolated_on_same_monitor
      monitor = FakeMonitor.new
      consumer_configuration = Julewire::Karafka::Configuration.new
      consumer_configuration.consumer_event_names = %w[consumer.one]
      producer_configuration = Julewire::Karafka::Configuration.new
      producer_configuration.producer_event_names = %w[producer.one]
      records = capture_records

      install_consumer_listener(monitor, configuration: consumer_configuration)
      install_producer_listener(monitor, configuration: producer_configuration)
      monitor.publish("consumer.one", FakeEvent.new)
      monitor.publish("producer.one", FakeEvent.new)

      assert_equal(%w[karafka.consumer_one waterdrop.producer_one], records.map { it.fetch(:event) })
    end

    def test_listener_swallow_subscription_failures_without_retrying
      configuration = Julewire::Karafka::Configuration.new
      configuration.consumer_event_names = %w[retry]
      consumer_monitor = EventFlakyMonitor.new(ArgumentError.new("arity"), fail_events: %w[retry])

      install_consumer_listener(consumer_monitor, configuration: configuration)

      assert_empty profile_subscriptions(consumer_monitor)
      assert_equal :degraded, Julewire.health.dig(:process_integrations, :karafka, :status)
      assert_equal :subscribe, Julewire.health.dig(:process_integrations, :karafka, :last_failure, :action)
      assert_equal :listener, Julewire.health.dig(:process_integrations, :karafka, :last_failure, :component)
      assert_equal "retry", Julewire.health.dig(:process_integrations, :karafka, :last_failure, :event)
    end

    def test_listener_turns_monitor_events_into_records
      records = capture_records
      listener = consumer_listener

      assert_nil listener.emit("error.occurred", FakeEvent.new(error: RuntimeError.new("boom")))

      record = records.fetch(0)

      assert_equal "karafka.error_occurred", record[:event]
      assert_equal :error, record[:severity]
      assert_equal "RuntimeError", record.dig(:error, :class)
      assert_nil record.dig(:payload, :error)
      assert_karafka_source_contract(record, event: "karafka.error_occurred", logger: "Karafka.monitor")
    end

    def test_listener_enriches_real_karafka_consumer_success_timeline
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
      assert_equal "consumer.consumed", consumed.dig(:neutral, :"messaging.operation.name")
      assert_equal "receive", consumed.dig(:neutral, :"messaging.operation.type")
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

      assert_false(records.any? { it[:event] == "karafka.consumer_consumed" })
      error_record = records.find { it[:event] == "karafka.error_occurred" }

      assert_equal :error, error_record[:severity]
      assert_equal "consumer.consume.error", error_record.dig(:attributes, :karafka, :type)
      assert_match(/\A[0-9a-f]{12}\z/, error_record.dig(:attributes, :karafka, :consumer_id))
      assert_equal 2, error_record.dig(:attributes, :karafka, :messages_count)
      assert_equal "RuntimeError", error_record.dig(:error, :class)
      assert_nil error_record.dig(:attributes, :karafka, :error)
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

    def test_listener_uses_non_hash_event_payload_for_fallback_severity
      assert_equal(
        :warn,
        captured_severity(consumer_listener, "process.notice_signal", FakeEvent.new(SignalPayload.new("ttin")))
      )
    end

    def test_listener_event_attributes_use_symbol_section_key
      assert_equal({ karafka: { topic: "events" } }, consumer_listener.event_attributes(topic: "events"))
    end

    def test_listener_contains_bad_events
      records = capture_records

      assert_nil consumer_listener.emit("custom.event", RaisingPayload.new)

      assert_equal "RuntimeError", records.fetch(0).dig(:attributes, :karafka, :payload_error, :exception_class)
    end

    def test_listener_records_adapter_failures
      listener = consumer_listener
      bad_name = Object.new

      assert_nil listener.emit(bad_name, FakeEvent.new)

      health = Julewire.health
      integration = health.dig(:process_integrations, :karafka)

      assert_equal :degraded, health.fetch(:status)
      assert_equal :degraded, integration.fetch(:status)
      assert_equal 1, integration.dig(:counts, :failures)
      assert_equal :listener, integration.dig(:last_failure, :component)
      assert_equal :emit, integration.dig(:last_failure, :action)
      assert_same bad_name, integration.dig(:last_failure, :event)
      assert_equal "NoMethodError", integration.dig(:last_failure, :class)
      refute_includes integration.fetch(:last_failure), :message
    end

    private

    def karafka_monitor(*events)
      notifications = ::Karafka::Core::Monitoring::Notifications.new
      events.each { notifications.register_event(it) }
      ::Karafka::Core::Monitoring::Monitor.new(notifications)
    end
  end
end
