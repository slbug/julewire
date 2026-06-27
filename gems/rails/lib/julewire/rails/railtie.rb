# frozen_string_literal: true

require "active_support/tagged_logging"
require "rails/rack/logger"

module Julewire
  module Rails
    class Railtie < ::Rails::Railtie
      config.julewire_rails = Configuration.new

      initializer "julewire_rails.logger", before: :initialize_logger do |app|
        Railtie.initialize_logger!(app)
      end

      initializer "julewire_rails.request_middleware", before: :build_middleware_stack do |app|
        Railtie.initialize_request_middleware!(app)
      end

      initializer "julewire_rails.exception_logging", before: :build_middleware_stack do |app|
        Railtie.initialize_exception_logging!(app)
      end

      config.after_initialize do |app|
        Railtie.finish_initialization!(app)
      end

      class << self
        def initialize_logger!(app)
          settings = validated_settings(app)
          return unless settings.logger?

          logger = Logger.new(name: settings.logger_name, source: settings.source)
          logger.level = app.config.log_level
          logger.formatter = app.config.log_formatter
          app.config.logger = ::ActiveSupport::TaggedLogging.new(logger)
          LoggerOutputs.install!
        end

        def initialize_request_middleware!(app)
          settings = validated_settings(app)
          return unless settings.request_middleware?

          install_request_middleware(app, settings, app.config.log_tags)
        end

        def initialize_exception_logging!(app)
          settings = validated_settings(app)
          configure_exception_logging(app, settings)
        end

        def finish_initialization!(app)
          settings = validated_settings(app)
          OutputRequirement.check!(settings)
          LifecycleHooks.install!(settings)
          install_subscribers(settings)
          DebugExceptionLogSilencer.install!(settings)
        end

        def install_subscribers(settings)
          Subscribers::ControllerResponse.install!(settings)
          settings.error_reports? ? Subscribers::Error.install!(settings) : Subscribers::Error.reset!
          Subscribers::RenderedException.install!(settings)
          if settings.structured_events?
            Subscribers::Event.install!(settings)
            LogSubscriberSilencer.silence! if settings.silence_log_subscribers?
          else
            Subscribers::Event.reset!
          end
        end

        def install_request_middleware(app, settings, log_tags = nil)
          operation = settings.replace_rack_logger? ? :swap : :insert_after
          app.config.middleware.public_send(operation, ::Rails::Rack::Logger, RequestMiddleware, settings, log_tags)
        rescue StandardError => e
          IntegrationHealth.record_failure(e, component: :request_middleware, action: :install)
          raise
        end

        def configure_exception_logging(app, settings)
          value = log_rescued_responses_value(settings)
          app.config.action_dispatch.log_rescued_responses = value unless value.nil?
        end

        def log_rescued_responses_value(settings)
          return settings.log_rescued_responses unless settings.log_rescued_responses == :auto

          false if settings.logger? && settings.request_summary?
        end

        private

        def validated_settings(app)
          app.config.julewire_rails.tap(&:validate!)
        end
      end
    end
  end
end
