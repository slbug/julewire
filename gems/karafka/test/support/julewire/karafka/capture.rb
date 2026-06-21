# frozen_string_literal: true

module JulewireCapture
  include Julewire::Core::Testing::Contracts

  def reset_julewire!
    Julewire.reset!
  end

  def capture_records
    Julewire::Core::Testing.capture
  end

  def consumer_listener
    Julewire::Karafka::MonitorListener.consumer
  end

  def producer_listener
    Julewire::Karafka::MonitorListener.producer
  end

  def install_consumer_listener(monitor, configuration: Julewire::Karafka::Configuration.new)
    app = fake_karafka_app(monitor)
    Julewire::Karafka::Installer.install!(app: app, configuration: configuration)
  end

  def install_producer_listener(monitor, configuration: Julewire::Karafka::Configuration.new)
    producer = Julewire::KarafkaTestSupport::FakeProducer.new(monitor)
    Julewire::Karafka::WaterdropInstaller.install!(producer, configuration: configuration)
  end

  def karafka_consumer(topic: :events, payloads: ["{}"], headers: {}, partition: 0, offsets: nil)
    consumer = @karafka.consumer_for(topic)
    offsets ||= Array.new(payloads.size) { it }

    payloads.zip(offsets).each do |payload, offset|
      @karafka.produce_to(
        consumer,
        payload,
        headers: headers,
        partition: partition,
        offset: offset
      )
    end

    consumer
  end

  def karafka_message(**)
    karafka_consumer(**).messages.first
  end

  def subscribe_all_events(listener_profile, monitor, setting)
    configuration = Julewire::Karafka::Configuration.new
    configuration.public_send("#{setting}=", :all)
    install_profile_listener(listener_profile, monitor, configuration)
  end

  def assert_available_event_subscriptions(listener_profile, setting:, events:)
    monitor = Julewire::KarafkaTestSupport::FakeMonitor.new(events)

    subscribe_all_events(listener_profile, monitor, setting)

    assert_equal events, profile_subscriptions(monitor)
  end

  def profile_subscriptions(monitor)
    Array(monitor.subscriptions) - %w[swarm.node.after_fork swarm.manager.after_fork]
  end

  def captured_severity(listener, event, payload)
    captured_record(listener, event, payload)[:severity]
  end

  def captured_record(listener, event, payload)
    records = capture_records
    listener.emit(event, payload)
    records.fetch(0)
  end

  def install_profile_listener(listener_profile, monitor, configuration)
    case listener_profile
    when :consumer
      install_consumer_listener(monitor, configuration: configuration)
    when :producer
      install_producer_listener(monitor, configuration: configuration)
    else
      listener_profile.call(monitor, configuration)
    end
  end

  def fake_karafka_app(monitor)
    config = Data.define(:monitor).new(monitor)
    Data.define(:config).new(config)
  end

  def assert_karafka_source_contract(record, event:, logger:)
    assert_julewire_record_source_contract(
      records: [record],
      event: event,
      source: "karafka",
      logger: logger,
      kind: "point",
      event_path: %i[event],
      source_path: %i[source],
      logger_path: %i[logger],
      kind_path: %i[kind]
    )
  end
end
