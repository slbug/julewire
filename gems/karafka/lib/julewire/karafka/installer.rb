# frozen_string_literal: true

module Julewire
  module Karafka
    module Installer
      class << self
        def install!(app: nil, monitor: nil, configuration: Configuration.new)
          return false unless configuration.enabled?

          monitor ||= monitor_for(app)
          raise Error, "Karafka monitor is not available" unless monitor

          ForkHooks.subscribe!(monitor, configuration: configuration)
          if configuration.consumer_events?
            MonitorSubscription.install!(monitor, configuration: configuration, profile: :consumer)
          end
          monitor
        end

        private

        def monitor_for(app)
          app ||= defined?(::Karafka::App) ? ::Karafka::App : nil
          app.config.monitor if app.respond_to?(:config)
        rescue StandardError
          nil
        end
      end
    end
  end
end
