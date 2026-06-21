# frozen_string_literal: true

module Julewire
  module Rails
    class RequestCompletion
      class << self
        def finish_instrumentation(instrumenter_handle)
          instrumenter_handle&.finish
        rescue StandardError
          nil
        ensure
          begin
            ::ActiveSupport::LogSubscriber.flush_all!
          rescue StandardError
            nil
          end
        end
      end

      def initialize(configuration:, execution_handle:, instrumenter_handle:, env:, request:, request_error:)
        @configuration = configuration
        @execution_handle = execution_handle
        @instrumenter_handle = instrumenter_handle
        @env = env
        @request = request
        @request_error = request_error
      end

      def attach(response)
        status, headers, body = response
        timeout_token = nil
        finish_once = completion_callback { RequestSummaryTimeoutScheduler.cancel(timeout_token) }
        install_response_finished_callback(finish_once)
        timeout_token = install_completion_timeout
        body = ContextBodyProxy.new(body, handle: @execution_handle, on_close: -> { finish_once.call(nil) })
        response.frozen? ? [status, headers, body] : response.tap { it[2] = body }
      end

      private

      def install_completion_timeout
        timeout = @configuration.request_summary_timeout
        return unless timeout

        context = completion_timeout_context
        RequestSummaryTimeoutScheduler.schedule(timeout) { emit_completion_timeout_warning(timeout, context) }
      end

      def install_response_finished_callback(finish_once)
        response_finished = @env["rack.response_finished"]
        return unless response_finished.respond_to?(:<<)

        response_finished << proc do |_rack_env, _status, _headers, error|
          finish_once.call(error)
        end
      end

      def completion_callback
        mutex = Mutex.new
        finished = false
        lambda do |error|
          mutex.synchronize do
            return if finished

            finished = true
          end
          yield if block_given?
          @execution_handle.with_context { finish_completion(error) }
        end
      end

      def finish_completion(error)
        self.class.finish_instrumentation(@instrumenter_handle)
        if error
          @execution_handle.finish(
            reason: :error,
            attributes: { rails: { completion: "error", completion_error_class: error.class.name } },
            error: error
          )
        elsif @request_error
          @execution_handle.finish(
            reason: :error,
            attributes: { rails: { completion: "error" } },
            error: @request_error.fetch(:error),
            severity: @request_error.fetch(:severity)
          )
        else
          @execution_handle.finish(reason: :closed, attributes: { rails: { completion: "closed" } })
        end
      end

      def completion_timeout_context
        return {} unless @configuration.request_context?

        {
          request_id: request_id,
          path: @request.path
        }.compact
      end

      def emit_completion_timeout_warning(timeout, context)
        record = {
          event: "request.completion_timeout",
          logger: @configuration.logger_name,
          source: @configuration.source,
          attributes: { rails: { completion_timeout_ms: (timeout * 1000).round } }
        }
        record[:context] = context unless context.empty?
        Julewire.warn(record)
      rescue StandardError
        nil
      end

      def request_id
        value = @request.request_id if @request.respond_to?(:request_id)
        value || @request.get_header("action_dispatch.request_id") || @request.get_header("HTTP_X_REQUEST_ID")
      end
    end
  end
end
