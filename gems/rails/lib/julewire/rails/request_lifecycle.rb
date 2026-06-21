# frozen_string_literal: true

module Julewire
  module Rails
    class RequestLifecycle
      attr_reader :execution_handle

      def initialize(configuration:, env:, request:, taggers:)
        @configuration = configuration
        @env = env
        @request = request
        @taggers = taggers
        @completion_attached = false
        @execution_handle = nil
        @instrumenter_handle = nil
        @tag_count = 0
      end

      def start
        @tag_count = push_tags
        @instrumenter_handle = start_request_instrumentation
        self
      end

      def start_execution!(neutral:)
        @execution_handle = Julewire.start_execution(
          type: :request,
          id: RequestAttributes.request_id(@request),
          neutral: neutral,
          emit_summary: @configuration.request_summary?,
          summary_event: @configuration.summary_event,
          summary_source: @configuration.source
        )
      end

      def attach_body_finalizer(response)
        finish_request_thread_logging
        @completion_attached = true
        RequestCompletion.new(
          configuration: @configuration,
          execution_handle: @execution_handle,
          instrumenter_handle: @instrumenter_handle,
          env: @env,
          request: @request,
          request_error: @env[RequestMiddleware::REQUEST_ERROR_ENV_KEY]
        ).attach(response)
      end

      def finish_error(error)
        @execution_handle&.finish(reason: :error, error: error)
      end

      def finish_unattached
        return if @completion_attached

        finish_unattached_request
        finish_request_thread_logging
      end

      private

      def push_tags
        return 0 unless ::Rails.logger.respond_to?(:push_tags)

        ::Rails.logger.push_tags(*compute_tags).size
      end

      def compute_tags
        @taggers.collect do |tag|
          case tag
          when Proc
            tag.call(@request)
          when Symbol
            @request.public_send(tag)
          else
            tag
          end
        end
      end

      def start_request_instrumentation
        handle = ::ActiveSupport::Notifications.instrumenter.build_handle(
          "request.action_dispatch",
          request: @request
        )
        handle.start
        handle
      end

      def finish_request_thread_logging
        return unless @tag_count.to_i.positive? && ::Rails.logger.respond_to?(:pop_tags)

        ::Rails.logger.pop_tags(@tag_count)
        @tag_count = 0
      rescue StandardError
        nil
      end

      def finish_unattached_request
        return RequestCompletion.finish_instrumentation(@instrumenter_handle) unless @execution_handle

        @execution_handle.with_context do
          RequestCompletion.finish_instrumentation(@instrumenter_handle)
          @execution_handle.finish(reason: :closed)
        end
      end
    end
  end
end
