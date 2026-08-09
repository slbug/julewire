# frozen_string_literal: true

module Julewire
  module Karafka
    module MonitorProfiles
      Profile = Data.define(
        :component,
        :event_prefix,
        :logger_name,
        :messaging_role,
        :config_method,
        :important_events,
        :severity
      )

      CONSUMER = Profile.new(
        component: :listener,
        event_prefix: "karafka",
        logger_name: "Karafka.monitor",
        messaging_role: :consumer,
        config_method: :consumer_event_names,
        important_events: Configuration::IMPORTANT_CONSUMER_EVENT_NAMES,
        severity: ->(name, event, payload) { EventSeverity.consumer(name, event: event, payload: payload) }
      ).freeze
      PRODUCER = Profile.new(
        component: :waterdrop_listener,
        event_prefix: "waterdrop",
        logger_name: "WaterDrop.monitor",
        messaging_role: :producer,
        config_method: :producer_event_names,
        important_events: Configuration::IMPORTANT_PRODUCER_EVENT_NAMES,
        severity: ->(name, _event, payload) { EventSeverity.producer(name, payload) }
      ).freeze
      private_constant :Profile, :CONSUMER, :PRODUCER

      class << self
        def consumer = CONSUMER

        def producer = PRODUCER
      end
    end

    private_constant :MonitorProfiles
  end
end
