# frozen_string_literal: true

module Julewire
  module Karafka
    module MonitorSubscription
      class << self
        def subscribe(monitor, event_name, component:, &)
          return false unless monitor.respond_to?(:subscribe)

          IntegrationHealth.with_failure_health(action: :subscribe, component:, event: event_name) do
            monitor.subscribe(event_name, &)
            true
          end
        end

        def install!(monitor, profile:, configuration:)
          state = subscription_state(monitor, profile)
          listener = listener_for(state, configuration, profile)
          subscriptions = subscriptions_for(state)
          desired_events = event_names(monitor, configuration, profile)

          unsubscribe_removed_events(monitor, subscriptions, desired_events, profile)

          desired_events.each do |event_name|
            next if subscriptions.key?(event_name)

            callback = ->(event) { listener.emit(event_name, event) }
            if subscribe(monitor, event_name, component: profile.component, &callback)
              subscriptions[event_name] = callback
            end
          end
          store_subscription_state(monitor, listener: listener, subscriptions: subscriptions, profile: profile)
        end

        private

        def listener_for(state, configuration, profile)
          listener = state&.fetch(:listener)
          if listener
            listener.configuration = configuration
            listener
          else
            MonitorListener.new(configuration, profile: profile)
          end
        end

        def subscriptions_for(state)
          return {} unless state

          state.fetch(:subscriptions)
        end

        def subscription_state(monitor, profile)
          subscription_state_store(profile).fetch(monitor)
        end

        def store_subscription_state(monitor, listener:, subscriptions:, profile:)
          subscription_state_store(profile).store(
            monitor,
            { listener: listener, subscriptions: subscriptions }
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
          selected_events =
            if configured == :important
              profile.important_events
            elsif all_events?(configured)
              available_events = available_events_for(monitor)
              available_events.empty? ? profile.important_events : available_events
            else
              Array(configured)
            end

          selected_events - profile.reserved_events
        end

        def available_events_for(monitor)
          available = direct_available_events(monitor)
          return available unless available.empty?

          available = notification_bus_available_events(monitor)
          return available unless available.empty?

          listener_event_names(monitor)
        end

        def direct_available_events(monitor)
          Array(Core::Integration::Values::Read.value(monitor, :available_events))
        end

        def notification_bus_available_events(monitor)
          bus = Core::Integration::Values::Read.value(monitor, :notifications_bus)

          Array(Core::Integration::Values::Read.value(bus, :available_events))
        end

        def listener_event_names(monitor)
          listeners = Core::Integration::Values::Read.value(monitor, :listeners)

          listeners.is_a?(Hash) ? listeners.keys : []
        end

        def all_events?(configured)
          %i[all available].include?(configured)
        end

        def unsubscribe_removed_events(monitor, subscriptions, desired_events, profile)
          return unless monitor.respond_to?(:unsubscribe)

          desired = desired_events.to_h { [it, true] }
          subscriptions.each_key do |event_name|
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
            monitor.unsubscribe(callback)
          end
        end
      end
    end

    private_constant :MonitorSubscription
  end
end
