# frozen_string_literal: true

module Julewire
  module Rails
    module Subscribers
      class Error
        class << self
          include Julewire::Core::Integration::SubscriberInstall

          def install!(configuration)
            return reset! unless configuration.error_reports?

            reporter = ::Rails.error
            return unless reporter.respond_to?(:subscribe)

            install_subscriber(configuration, enabled: true) do |subscriber|
              Julewire::RailsSupport::EventReporter.subscribe(reporter, subscriber)
            end
          end
        end

        def initialize(configuration = Configuration.new)
          @configuration = configuration
        end

        attr_writer :configuration

        def report(error, handled:, severity:, context:, source:)
          return unless @configuration.error_reports?
          return if Suppression.active?
          return if request_owned_dispatch_error?(error, handled, source)

          Julewire::Core::Integration::Facade.emit(
            severity: julewire_severity(severity),
            event: "rails.error",
            logger: "Rails.error",
            source: @configuration.source,
            context: hash_or_empty(context),
            attributes: { rails: {
              handled: handled,
              source: source
            } },
            error: error
          )
          IntegrationHealth.record_success
        rescue StandardError => e
          IntegrationHealth.record_failure(
            e,
            action: :report,
            component: :error_subscriber
          )
        end

        private

        def request_owned_dispatch_error?(error, handled, source)
          handled == false &&
            source == "application.action_dispatch" &&
            RequestErrorOwnership.consume?(error)
        end

        def julewire_severity(severity)
          return :warn if [:warning, "warning"].include?(severity)

          severity
        end

        def hash_or_empty(value)
          values = Julewire::Core::Integration::Values::Shape
          normalize_context(values.hash_or_empty(value))
        end

        def normalize_context(context)
          controller = context[:controller]
          return context if controller.nil? || controller.is_a?(String)

          context.merge(controller: controller.class.name || controller.to_s)
        end
      end
    end
  end
end
