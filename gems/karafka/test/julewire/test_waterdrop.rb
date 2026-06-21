# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestKarafkaWaterdrop < Minitest::Test
    include JulewireCapture

    cover Julewire::Karafka::WaterdropMiddleware

    BasicMonitor = KarafkaTestSupport::BasicMonitor
    FakeEvent = KarafkaTestSupport::FakeEvent
    FakeMonitor = KarafkaTestSupport::FakeMonitor
    FakeMonitorWithDangerousListeners = KarafkaTestSupport::FakeMonitorWithDangerousListeners
    FakeProducer = KarafkaTestSupport::FakeProducer
    FlakyMonitor = KarafkaTestSupport::FlakyMonitor
    MutableMessage = KarafkaTestSupport::MutableMessage

    def setup
      super
      reset_julewire!
    end

    def test_waterdrop_middleware_injects_carrier_into_message_headers
      message = { topic: "events", payload: "{}", headers: {} }

      Julewire.with_execution(type: :request, id: "request-1") do
        Julewire.context.add(request_id: "request-1")
        Julewire::Karafka.inject!(message)
      end

      assert message[:headers]["julewire"]
    end

    def test_waterdrop_middleware_injects_carrier_through_karafka_testing_producer
      with_karafka_producer_middleware_snapshot do |producer|
        configuration = Julewire::Karafka::Configuration.new
        configuration.producer_events = false
        Julewire::Karafka.install!(consumer: false, producer: producer, configuration: configuration)

        Julewire.with_execution(type: :request, id: "request-1") do
          Julewire.context.add(request_id: "request-1")
          @karafka.produce("{}", topic: :events, headers: {})
        end

        message = @karafka.produced_messages.fetch(0)
        envelope = Julewire::Core::Propagation::Carrier.extract(message.fetch(:headers))

        assert message.fetch(:headers).fetch("julewire")
        assert_equal "request-1", envelope.dig(:context, :request_id)
      end
    end

    def test_waterdrop_installer_prepends_middleware_and_subscribes_listener
      producer = FakeProducer.new

      Julewire::Karafka.install!(consumer: false, producer: producer)

      assert_producer_installed(producer)
    end

    def test_install_helper_can_install_consumer_and_producer
      monitor = FakeMonitor.new
      producer = FakeProducer.new

      result = Julewire::Karafka.install!(monitor: monitor, producer: producer)

      assert_producer_installed(producer)
      assert_same monitor, result.consumer
      assert_same producer, result.producer
      assert_includes monitor.subscriptions, "consumer.consumed"
    end

    def test_waterdrop_installer_is_idempotent
      producer = FakeProducer.new
      disabled = Julewire::Karafka::Configuration.new
      disabled.propagation = false

      Julewire::Karafka.install!(consumer: false, producer: producer)
      Julewire::Karafka.install!(consumer: false, producer: producer)
      Julewire::Karafka.install!(consumer: false, producer: producer, configuration: disabled)

      assert_equal 1, producer.middleware.items.size
      assert_equal producer.monitor.subscriptions.uniq, producer.monitor.subscriptions
      assert_nil producer.middleware.items.fetch(0).call(headers: {}).fetch(:headers)["julewire"]
    end

    def test_waterdrop_listener_defaults_to_important_event_profile
      monitor = BasicMonitor.new

      install_producer_listener(monitor)

      assert_includes monitor.subscriptions, "message.produced_sync"
      refute_includes monitor.subscriptions, "statistics.emitted"
    end

    def test_producer_static_event_names_exist_in_waterdrop_catalog
      require "waterdrop/instrumentation/notifications"

      events = Julewire::Karafka::Configuration::IMPORTANT_PRODUCER_EVENT_NAMES +
               Julewire::Karafka::EventSeverity.const_get(:DEBUG_PRODUCER_EVENTS, false)
      missing = events.uniq - ::WaterDrop::Instrumentation::Notifications::EVENTS

      assert_empty missing
    end

    def test_waterdrop_listener_can_subscribe_to_all_monitor_available_events
      assert_available_event_subscriptions(
        :producer,
        setting: :producer_event_names,
        events: %w[custom.producer custom.error]
      )
    end

    def test_waterdrop_listener_can_subscribe_to_real_waterdrop_monitor_events
      require "waterdrop"

      producer_monitor = ::WaterDrop::Instrumentation::Monitor.new

      subscribe_all_events(:producer, producer_monitor, :producer_event_names)

      refute_empty producer_monitor.listeners.fetch("message.produced_sync")
      refute_empty producer_monitor.listeners.fetch("poller.producer_registered")
    end

    def test_waterdrop_listener_can_subscribe_to_default_all_events_without_available_events
      producer_monitor = BasicMonitor.new

      subscribe_all_events(:producer, producer_monitor, :producer_event_names)

      assert_includes producer_monitor.subscriptions, "message.produced_sync"
    end

    def test_waterdrop_listener_accepts_explicit_event_lists_and_ignores_bad_monitors
      configuration = Julewire::Karafka::Configuration.new
      configuration.producer_event_names = %w[three]
      producer_monitor = FakeMonitor.new

      install_producer_listener(producer_monitor, configuration: configuration)

      assert_equal %w[three], profile_subscriptions(producer_monitor)
      assert_instance_of Julewire::KarafkaTestSupport::FakeProducer,
                         install_producer_listener(Object.new)
    end

    def test_waterdrop_listener_swallows_subscription_failures_without_retrying
      configuration = Julewire::Karafka::Configuration.new
      configuration.producer_event_names = %w[retry]
      producer_monitor = FlakyMonitor.new(ArgumentError.new("arity"))

      install_producer_listener(producer_monitor, configuration: configuration)

      assert_empty profile_subscriptions(producer_monitor)
      assert_equal :degraded, Julewire.health.dig(:process_integrations, :karafka, :status)
      assert_equal :waterdrop_listener, Julewire.health.dig(:process_integrations, :karafka, :last_failure, :component)

      producer_monitor = FlakyMonitor.new(RuntimeError.new("boom"))

      assert_instance_of Julewire::KarafkaTestSupport::FakeProducer,
                         install_producer_listener(producer_monitor, configuration: configuration)
    end

    def test_waterdrop_installer_does_not_scan_existing_monitor_listeners
      producer = FakeProducer.new(FakeMonitorWithDangerousListeners.new)

      Julewire::Karafka.install!(consumer: false, producer: producer)

      assert_includes producer.monitor.subscriptions, "message.produced_sync"
    end

    def test_waterdrop_middleware_omits_oversized_carrier
      configuration = Julewire::Karafka::Configuration.new
      configuration.carrier_max_bytes = 10
      message = { headers: {} }

      Julewire.context.with(request_id: "request-1") do
        Julewire::Karafka.inject!(message, configuration: configuration)
      end

      assert_empty message[:headers]
    end

    def test_waterdrop_middleware_handles_object_messages_and_disabled_propagation
      configuration = Julewire::Karafka::Configuration.new
      configuration.propagation = false
      message = MutableMessage.new("events", 0, 42, nil)

      result = Julewire::Karafka::WaterdropMiddleware.new(configuration: configuration).call(message)

      assert_same message, result
      assert_nil message.headers

      Julewire::Karafka::WaterdropMiddleware.new.call(message)

      assert_kind_of Hash, message.headers
    end

    def test_waterdrop_middleware_contains_bad_message_headers
      message = KarafkaTestSupport::BadMessage.new

      assert_same message, Julewire::Karafka::WaterdropMiddleware.new.call(message)
      assert_equal :degraded, Julewire.health.dig(:process_integrations, :karafka, :status)
      assert_equal :carrier_inject, Julewire.health.dig(:process_integrations, :karafka, :last_failure, :action)
    end

    def test_waterdrop_listener_uses_monitor_payload_severity_when_present
      assert_equal(
        :debug,
        captured_severity(producer_listener, "custom.event", FakeEvent.new(level: :debug))
      )
    end

    def test_waterdrop_listener_matches_error_severity
      record = captured_record(
        producer_listener,
        "error.occurred",
        FakeEvent.new(error: RuntimeError.new("boom"))
      )

      assert_equal :error, record[:severity]
      assert_karafka_source_contract(record, event: "waterdrop.error_occurred", logger: "WaterDrop.monitor")
    end

    def test_waterdrop_listener_matches_debug_and_info_severities
      records = capture_records
      listener = producer_listener

      listener.emit("statistics.emitted", FakeEvent.new)
      listener.emit("message.acknowledged", FakeEvent.new)

      assert_equal(%i[debug info], records.map { it[:severity] })
    end

    def test_waterdrop_installer_contains_bad_producers
      producer = Object.new
      def producer.middleware = raise("middleware failed")
      def producer.monitor = raise("monitor failed")

      assert_same producer, Julewire::Karafka.install!(consumer: false, producer: producer)
      assert_equal :degraded, Julewire.health.dig(:process_integrations, :karafka, :status)
      assert_equal :install, Julewire.health.dig(:process_integrations, :karafka, :last_failure, :action)
      assert_equal :waterdrop_installer, Julewire.health.dig(:process_integrations, :karafka, :last_failure, :component)
    end

    def test_waterdrop_installer_respects_enabled_and_feature_toggles
      configuration = Julewire::Karafka::Configuration.new
      producer = FakeProducer.new

      configuration.enabled = false

      refute Julewire::Karafka.install!(consumer: false, producer: producer, configuration: configuration)

      configuration.enabled = true
      configuration.propagation = false
      configuration.producer_events = false

      assert_same producer,
                  Julewire::Karafka.install!(consumer: false, producer: producer, configuration: configuration)
      assert_empty producer.middleware.items
      assert_empty producer.monitor.subscriptions
    end

    def test_waterdrop_installer_handles_missing_middleware_and_monitor
      producer = Object.new

      assert_same producer, Julewire::Karafka.install!(consumer: false, producer: producer)
    end

    private

    def assert_producer_installed(producer)
      assert_equal 1, producer.middleware.items.size
      assert_includes producer.monitor.subscriptions, "message.produced_sync"
      refute_includes producer.monitor.subscriptions, "statistics.emitted"
    end

    def with_karafka_producer_middleware_snapshot
      producer = ::Karafka.producer
      middleware = producer.middleware
      steps = middleware.instance_variable_get(:@steps)&.dup
      count = middleware.instance_variable_get(:@count)
      installed = producer.instance_variable_get(:@julewire_karafka_waterdrop_middleware)
      yield producer
    ensure
      middleware.instance_variable_set(:@steps, steps) if defined?(middleware) && steps
      middleware.instance_variable_set(:@count, count) if defined?(middleware)
      producer.instance_variable_set(:@julewire_karafka_waterdrop_middleware, installed) if defined?(producer)
    end
  end
end
