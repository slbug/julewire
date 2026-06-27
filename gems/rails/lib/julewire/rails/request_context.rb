# frozen_string_literal: true

module Julewire
  module Rails
    class RequestContext
      def initialize(
        configuration:,
        request:,
        active_support_context: Julewire::Core::UNSET,
        event_reporter: Julewire::Core::UNSET
      )
        @configuration = configuration
        @request = request
        @active_support_context = default_provider(active_support_context) { ::ActiveSupport::ExecutionContext }
        @event_reporter = default_provider(event_reporter) { Julewire::RailsSupport::EventReporter.default }
      end

      def neutral_fields
        RequestAttributes.request(@request)
      end

      def call(&)
        with_request_carry do
          with_request_context(&)
        end
      end

      private

      def default_provider(value)
        value.equal?(Julewire::Core::UNSET) ? yield : value
      end

      def with_request_context(&)
        return yield unless @configuration.request_context?

        fields = RequestAttributes.context_fields(@request)
        Julewire::Core::Integration::Facade.with_context(fields) do
          with_active_support_execution_context(fields) do
            with_rails_event_context(fields, &)
          end
        end
      end

      def with_request_carry(&)
        return yield unless @configuration.carry_request_headers
        raise ArgumentError, "carry_request_headers must be an explicit header list" if all_carry_headers?

        headers = Julewire::Rack::Capture::Headers.request(
          @request,
          selector: @configuration.carry_request_headers
        )
        return yield if headers.empty?

        headers = RequestAttributes.normalize_user_fields(headers)
        Julewire::Core::Integration::Facade.with_carry(http: { request_headers: headers }, &)
      end

      def all_carry_headers?
        @configuration.carry_request_headers == true
      end

      def with_active_support_execution_context(fields, &)
        return yield unless @active_support_context.respond_to?(:set)

        @active_support_context.set(**fields, &)
      end

      def with_rails_event_context(fields)
        return yield unless rails_event_context_supported?

        previous = nil
        context_set = false
        begin
          previous = @event_reporter.context
          @event_reporter.set_context(fields)
          context_set = true
        rescue StandardError
          nil
        end
        yield
      ensure
        restore_rails_event_context(previous) if context_set
      end

      def rails_event_context_supported?
        @event_reporter.respond_to?(:context) &&
          @event_reporter.respond_to?(:set_context) &&
          @event_reporter.respond_to?(:clear_context)
      end

      def restore_rails_event_context(previous)
        return unless clear_rails_event_context
        return if previous.nil? || previous.empty?

        apply_rails_event_context(previous)
      end

      def clear_rails_event_context
        @event_reporter.clear_context
        true
      rescue StandardError
        false
      end

      def apply_rails_event_context(previous)
        @event_reporter.set_context(previous)
      rescue StandardError
        nil
      end
    end
  end
end
