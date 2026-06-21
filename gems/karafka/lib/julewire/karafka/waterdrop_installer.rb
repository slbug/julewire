# frozen_string_literal: true

module Julewire
  module Karafka
    module WaterdropInstaller
      MIDDLEWARE_INSTALL = Core::Integration::IvarState.new(:@julewire_karafka_waterdrop_middleware)

      class << self
        def install!(producer, configuration: Configuration.new)
          return false unless configuration.enabled?

          install_or_update_middleware(producer, configuration) if middleware_needed?(producer, configuration)
          install_listener(producer, configuration) if configuration.producer_events?
          producer
        end

        private

        def middleware_needed?(producer, configuration)
          configuration.propagation? || installed_middleware(producer)
        end

        def install_or_update_middleware(producer, configuration)
          install_middleware(producer, configuration)
        end

        def install_middleware(producer, configuration)
          existing = MIDDLEWARE_INSTALL.fetch(producer)
          if existing
            existing.configuration = configuration
            return existing
          end

          middleware = producer.middleware if producer.respond_to?(:middleware)
          return unless middleware.respond_to?(:prepend)

          installed = WaterdropMiddleware.new(configuration: configuration)
          middleware.prepend(installed)
          MIDDLEWARE_INSTALL.store(producer, installed)
          installed
        rescue StandardError => e
          IntegrationHealth.record_failure(e, action: :install, component: :waterdrop_installer)
          nil
        end

        def install_listener(producer, configuration)
          monitor = producer.monitor if producer.respond_to?(:monitor)
          MonitorSubscription.install!(monitor, configuration: configuration, profile: :producer) if monitor
        rescue StandardError => e
          IntegrationHealth.record_failure(e, action: :install, component: :waterdrop_installer)
          nil
        end

        def installed_middleware(producer)
          MIDDLEWARE_INSTALL.fetch(producer)
        end
      end
    end
  end
end
