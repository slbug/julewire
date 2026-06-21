# frozen_string_literal: true

module Julewire
  module Karafka
    module MonitorSubscription
      PROFILE_CONSTANTS = {
        consumer: :CONSUMER_PROFILE,
        producer: :PRODUCER_PROFILE
      }.freeze
      private_constant :PROFILE_CONSTANTS

      class << self
        def install!(monitor, profile:, configuration: Configuration.new)
          profile = monitor_listener_profile(profile)
          state = subscription_state(monitor, profile)
          listener = listener_for(state, configuration, profile)
          subscriptions = subscriptions_for(state)
          desired_events = event_names(monitor, configuration, profile)

          unsubscribe_removed_events(monitor, subscriptions, desired_events, profile)

          desired_events.each do |event_name|
            next if subscriptions.key?(event_name)

            callback = ->(event) { listener.emit(event_name, event) }
            subscriptions[event_name] = callback if subscribe_event(monitor, event_name, profile, &callback)
          end
          store_subscription_state(monitor, listener: listener, subscriptions: subscriptions, profile: profile)
          listener
        end

        private

        def monitor_listener_profile(profile)
          constant_name = PROFILE_CONSTANTS.fetch(profile) { return profile }
          MonitorListener.const_get(constant_name, false)
        end

        def listener_for(state, configuration, profile)
          listener = state && state[:listener]
          if listener
            listener.configuration = configuration
            listener
          else
            MonitorListener.new(configuration, profile: profile)
          end
        end

        def subscriptions_for(state)
          return {} unless state

          state[:subscriptions].is_a?(Hash) ? state[:subscriptions].dup : {}
        end

        def subscription_state(monitor, profile)
          subscription_state_store(profile).fetch(monitor)
        end

        def store_subscription_state(monitor, listener:, subscriptions:, profile:)
          subscription_state_store(profile).store(
            monitor,
            { listener: listener, subscriptions: subscriptions.freeze }.freeze
          )
        end

        def install_marker(profile)
          :"@julewire_karafka_#{profile.component}_state"
        end

        def subscription_state_store(profile)
          Core::Integration::IvarState.new(install_marker(profile))
        end

        def event_names(monitor, configuration, profile)
          configured = configuration.public_send(profile.config_method)
          return profile.important_events if configured == :important

          if all_events?(configured)
            available_events = available_events_for(monitor)
            return available_events unless available_events.empty?

            return profile.important_events
          end

          Array(configured)
        end

        def available_events_for(monitor)
          available = direct_available_events(monitor)
          return available unless available.empty?

          available = notification_bus_available_events(monitor)
          return available unless available.empty?

          listener_event_names(monitor)
        end

        def direct_available_events(monitor)
          return [] unless monitor.respond_to?(:available_events)

          Array(monitor.available_events)
        rescue StandardError
          []
        end

        def notification_bus_available_events(monitor)
          return [] unless monitor.respond_to?(:notifications_bus)

          bus = monitor.notifications_bus
          return [] unless bus.respond_to?(:available_events)

          Array(bus.available_events)
        rescue StandardError
          []
        end

        def listener_event_names(monitor)
          return [] unless monitor.respond_to?(:listeners)

          listeners = monitor.listeners
          listeners.is_a?(Hash) ? listeners.keys : []
        rescue StandardError
          []
        end

        def all_events?(configured)
          %i[all available].include?(configured)
        end

        def unsubscribe_removed_events(monitor, subscriptions, desired_events, profile)
          return unless monitor.respond_to?(:unsubscribe)

          desired = desired_events.to_h { [it, true] }
          subscriptions.each_key.to_a.each do |event_name|
            next if desired.key?(event_name)

            callback = subscriptions.delete(event_name)
            unsubscribe_event(monitor, event_name, callback, profile)
          end
        end

        def unsubscribe_event(monitor, event_name, callback, profile)
          IntegrationHealth.with_failure_health(
            action: :unsubscribe,
            component: profile.component,
            event: event_name
          ) do
            monitor.unsubscribe(callback || event_name)
            true
          end
        end

        def subscribe_event(monitor, event_name, profile, &)
          return false unless monitor.respond_to?(:subscribe)

          IntegrationHealth.with_failure_health(action: :subscribe, component: profile.component, event: event_name) do
            monitor.subscribe(event_name, &)
            true
          end || false
        end
      end
    end

    private_constant :MonitorSubscription
  end
end
