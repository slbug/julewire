# frozen_string_literal: true

require "zeitwerk"
require "julewire/core"

module Julewire
  module Karafka
    class Error < Julewire::Error; end
    IntegrationHealth = Core::Integration::Health.scoped(:karafka)

    extend Core::Integration::Configurable

    configurable_with { Configuration }

    InstallResult = Data.define(:consumer, :producer)

    class << self
      def install!(app: nil, monitor: nil, producer: nil, consumer: true, configuration: config)
        return false unless configuration.enabled?

        consumer_result = Installer.install!(app: app, monitor: monitor, configuration: configuration) if consumer
        producer_result = WaterdropInstaller.install!(producer, configuration: configuration) if producer

        return InstallResult.new(consumer_result, producer_result) if consumer && producer

        producer ? producer_result : consumer_result
      end

      def inject!(message, configuration: config)
        WaterdropMiddleware.new(configuration: configuration).call(message)
      end

      def with_message(message, configuration: config, &)
        MessageContext.call(message, configuration: configuration, &)
      end

      def with_message_execution(message, configuration: config, **execution_options, &)
        MessageExecution.call(message, configuration: configuration, **execution_options, &)
      end
    end
  end

  loader = Zeitwerk::Loader.for_gem_extension(self)
  loader.setup
end
