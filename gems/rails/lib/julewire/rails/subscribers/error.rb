# frozen_string_literal: true

module Julewire
  module Rails
    module Subscribers
      class Error
        class << self
          include Core::Integration::SubscriberInstall

          def install!(configuration)
            return reset! unless configuration.error_reports?
            return unless defined?(::Rails) && ::Rails.respond_to?(:error)
            return unless ::Rails.error.respond_to?(:subscribe)

            reporter = ::Rails.error
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

          Core::Integration::Facade.emit(
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
          IntegrationHealth.record_success(action: :report, component: :error_subscriber)
        rescue StandardError => e
          IntegrationHealth.record_failure(
            e,
            action: :report,
            component: :error_subscriber
          )
        end

        private

        def request_owned_dispatch_error?(error, handled, source)
          return false unless handled == false
          return false unless source == "application.action_dispatch"

          RequestErrorOwnership.consume?(error)
        end

        def julewire_severity(severity)
          severity.to_sym == :warning ? :warn : severity
        rescue StandardError
          severity
        end

        def hash_or_empty(value)
          return {} unless value.is_a?(Hash)

          values = Core::Integration::Values::Shape
          normalize_context(values.hash_or_empty(value))
        end

        def normalize_context(context)
          controller = context[:controller]
          return context unless context.key?(:controller)
          return context if controller.nil? || controller.is_a?(String)

          context.merge(controller: controller.class.name || controller.to_s)
        end
      end
    end
  end
end
