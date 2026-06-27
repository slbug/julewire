# frozen_string_literal: true

module Julewire
  module Karafka
    module WaterdropInstaller
      MIDDLEWARE_INSTALL = Core::Integration::IvarState.new(:@julewire_karafka_waterdrop_middleware)

      class << self
        def install!(producer, configuration:)
          install_middleware(producer, configuration) if middleware_needed?(producer, configuration)
          install_listener(producer, configuration) if configuration.producer_events?
          producer
        end

        private

        def middleware_needed?(producer, configuration)
          configuration.propagation? || installed_middleware(producer)
        end

        def install_middleware(producer, configuration)
          existing = MIDDLEWARE_INSTALL.fetch(producer)
          if existing
            existing.configuration = configuration
            return
          end

          return unless producer.respond_to?(:middleware)

          middleware = producer.middleware
          return unless middleware.respond_to?(:prepend)

          installed = WaterdropMiddleware.new(configuration: configuration)
          middleware.prepend(installed)
          MIDDLEWARE_INSTALL.store(producer, installed)
        rescue StandardError => e
          IntegrationHealth.record_failure(e, action: :install, component: :waterdrop_installer)
        end

        def install_listener(producer, configuration)
          return unless producer.respond_to?(:monitor)

          monitor = producer.monitor
          MonitorSubscription.install!(monitor, configuration: configuration, profile: :producer)
        rescue StandardError => e
          IntegrationHealth.record_failure(e, action: :install, component: :waterdrop_installer)
        end

        def installed_middleware(producer)
          MIDDLEWARE_INSTALL.fetch(producer)
        end
      end
    end
  end
end
