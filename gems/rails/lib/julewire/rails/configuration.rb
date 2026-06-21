# frozen_string_literal: true

module Julewire
  module Rails
    class Configuration
      include Julewire::Core::Integration::Settings

      setting :logger, default: true, predicate: true
      setting :logger_name, default: "Rails"
      setting :carry_request_headers, default: false, validate: :validate_carry_request_headers
      setting :error_reports, default: true, predicate: true
      setting :filter_event_payloads, default: true, predicate: true
      setting :lifecycle_hooks, default: true, predicate: true
      setting :log_rescued_responses, default: :auto
      setting :reported_exception_logs, default: :auto
      setting(:request_capture, validate: :validate_capture_settings) { Julewire::Rack::Capture::Settings.new }
      setting :request_context, default: true, predicate: true
      setting :request_exclude_prefixes, default: [], validate: :validate_request_exclude_prefixes
      setting :request_middleware, default: true, predicate: true
      setting :require_output, default: :warn
      setting :request_summary, default: true, predicate: true
      setting :request_summary_timeout, default: 30, validate: :validate_request_summary_timeout
      setting :replace_rack_logger, default: true, predicate: true
      setting(:response_capture, validate: :validate_capture_settings) { Julewire::Rack::Capture::Settings.new }
      setting :rendered_exceptions, default: false, predicate: true
      setting :silence_log_subscribers, default: :auto
      setting :shutdown_timeout, default: 1
      setting :source, default: "rails"
      setting :structured_event_exclude_names, default: []
      setting :structured_event_exclude_prefixes, default: []
      setting :structured_event_names, default: []
      setting :structured_event_prefixes, default: %w[action_controller. action_dispatch. active_record.]
      setting :structured_events, default: true, predicate: true
      setting :summary_event, default: "request.completed"

      def controller_capture?
        request_capture.enabled? || response_capture.enabled?
      end

      def silence_log_subscribers?
        return logger? if silence_log_subscribers == :auto

        !!silence_log_subscribers
      end

      private

      def validate_carry_request_headers(value)
        return value unless value == true

        raise Error, "carry_request_headers must be an explicit header list"
      end

      def validate_request_summary_timeout(value)
        return value if value.nil?
        return value if value.is_a?(Numeric) && value.positive?

        raise Error, "request_summary_timeout must be nil or a positive Numeric"
      end

      def validate_request_exclude_prefixes(value)
        prefixes = Array(value)
        return prefixes if prefixes.all? { it.is_a?(String) && it.start_with?("/") && !it.empty? }

        raise Error, "request_exclude_prefixes must contain absolute path prefixes"
      end

      def validate_capture_settings(settings)
        settings.validate!
        settings
      end
    end
  end
end
