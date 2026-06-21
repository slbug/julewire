# frozen_string_literal: true

require "active_support/tagged_logging"
require "rails/rack/logger"

module Julewire
  module Rails
    class Railtie < ::Rails::Railtie
      config.julewire_rails = Configuration.new

      initializer "julewire_rails.logger", before: :initialize_logger do |app|
        settings = app.config.julewire_rails
        settings.validate!
        next unless settings.logger?

        logger = Logger.new(name: settings.logger_name, source: settings.source)
        logger.level = ::Logger::Severity.const_get(app.config.log_level.to_s.upcase)
        logger.formatter = app.config.log_formatter if app.config.respond_to?(:log_formatter)
        app.config.logger = ::ActiveSupport::TaggedLogging.new(logger)
        LoggerOutputs.install!
      end

      initializer "julewire_rails.request_middleware", before: :build_middleware_stack do |app|
        settings = app.config.julewire_rails
        settings.validate!
        next unless settings.request_middleware?

        self.class.install_request_middleware(app, settings, app.config.log_tags)
      end

      initializer "julewire_rails.exception_logging", before: :build_middleware_stack do |app|
        settings = app.config.julewire_rails
        settings.validate!
        self.class.configure_exception_logging(app, settings)
      end

      config.after_initialize do |app|
        settings = app.config.julewire_rails
        settings.validate!
        OutputRequirement.check!(settings)
        LifecycleHooks.install!(settings)
        Railtie.install_subscribers(settings)
        DebugExceptionLogSilencer.install!(settings)
      end

      class << self
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
          if settings.log_rescued_responses == :auto
            return false if settings.logger? && settings.request_summary?

            return
          end

          settings.log_rescued_responses
        end
      end
    end
  end
end
