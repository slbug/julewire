# frozen_string_literal: true

module Julewire
  module Karafka
    module Installer
      class << self
        def install!(app:, configuration:, monitor: nil)
          monitor ||= monitor_for(app)
          raise Error, "Karafka monitor is not available" unless monitor

          ForkHooks.subscribe!(monitor, configuration: configuration)
          if configuration.consumer_events?
            MonitorSubscription.install!(monitor, configuration: configuration, profile: MonitorProfiles.consumer)
          end
          monitor
        end

        private

        def monitor_for(app)
          Core::Integration::Values::Read.nested_value(app, :config, :monitor)
        end
      end
    end
  end
end
