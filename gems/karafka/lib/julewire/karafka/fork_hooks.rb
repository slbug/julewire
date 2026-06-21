# frozen_string_literal: true

module Julewire
  module Karafka
    module ForkHooks
      EVENTS = %w[
        swarm.node.after_fork
        swarm.manager.after_fork
      ].freeze
      INSTALL_STATE = Core::Integration::IvarState.new(:@julewire_karafka_fork_hooks_state)
      private_constant :EVENTS, :INSTALL_STATE

      class << self
        def subscribe!(monitor, configuration: Configuration.new)
          return unless configuration.enabled?
          return unless monitor.respond_to?(:subscribe)

          state = INSTALL_STATE.fetch_or_store(monitor) { { events: [].freeze }.freeze }
          subscribed_events = Array(state[:events]).dup
          EVENTS.each do |event_name|
            next if subscribed_events.include?(event_name)

            subscribed_events << event_name if subscribe_event(monitor, event_name)
          end
          INSTALL_STATE.store(monitor, { events: subscribed_events.freeze }.freeze)
          monitor
        end

        def handle(event_name, _event)
          IntegrationHealth.with_failure_health(action: :after_fork, component: :fork_hooks, event: event_name) do
            Julewire.after_fork!
          end
        end

        private

        def subscribe_event(monitor, event_name)
          IntegrationHealth.with_failure_health(action: :subscribe, component: :fork_hooks, event: event_name) do
            monitor.subscribe(event_name) { handle(event_name, it) }
            true
          end || false
        end
      end
    end
  end
end
