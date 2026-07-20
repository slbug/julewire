# frozen_string_literal: true

module Julewire
  module Ractor
    class RemoteRuntime
      DEFAULT_REQUEST_TIMEOUT = 1
      REQUEST_TIMEOUT = ::Ractor.make_shareable(Object.new)

      def initialize(port:, emit_non_standard_exception_summaries: false)
        @port = port
        @child_stats = ChildStats.new
        @emit_non_standard_exception_summaries = emit_non_standard_exception_summaries
        @request_mutex = Mutex.new
        @timeout_scheduler = ReplyTimeoutScheduler.new(timeout_value: REQUEST_TIMEOUT)
        @execution_boundary = build_execution_boundary
      end

      def config = raise Core::Error, "Julewire.config is not available inside Julewire.ractor"

      def configure = raise Core::Error, "Julewire.configure is not available inside Julewire.ractor"

      def context = Core::ContextStore.current.context_proxy

      def attributes = Core::ContextStore.current.attributes_proxy

      def carry = Core::ContextStore.current.carry_proxy

      def summary = Core::ContextStore.current.summary_proxy

      def current_execution = current_scope && Core::Execution::View.new(current_scope)

      def current_execution? = !!current_scope

      def with_execution(...) = @execution_boundary.with_execution(...)

      def start_execution(...) = @execution_boundary.start_execution(...)

      def child_stats = @child_stats.to_h

      def reset_child_stats! = @child_stats.reset!

      def emit(record = Core::UNSET, **fields, &)
        remote_emit(:emit, record, fields, &)
      end

      def emit_without_level(record = Core::UNSET, **fields, &)
        remote_emit(:emit_without_level, record, fields, &)
      end

      def emit_integration(record, enforce_level:)
        command = enforce_level ? :emit : :emit_without_level
        input = Core::Records::BuildInput.validate_owned(record)
        notify(command, payload: remote_emit_payload(input))
      rescue StandardError => e
        @child_stats.message_dropped(e)
      end

      def remote_emit(command, record, fields, &)
        record = Core.emit_input(record, fields)
        record = Core::Records::LazyEmitInput.call(record, &) if block_given?
        input = Core::Records::BuildInput.normalize_public(record)
        input = Core::Fields::FieldSet.deep_symbolize_keys(input)
        notify(command, payload: remote_emit_payload(input))
      rescue StandardError => e
        @child_stats.message_dropped(e)
      end
      private :remote_emit

      def flush(timeout: Core::UNSET)
        timeout = effective_timeout(timeout)
        Core::Validation.validate_timeout!(timeout, name: :timeout)
        request(:flush, timeout: timeout)
      end

      def after_fork!(**)
        raise Core::Error, "Julewire.after_fork! is not available inside Julewire.ractor"
      end

      def health
        raise Core::Error, "Julewire.health is not available inside Julewire.ractor"
      end

      def close(**)
        raise Core::Error, "Julewire.close is not available inside Julewire.ractor; use Julewire.flush instead"
      end

      def labels
        raise Core::Error, "Julewire.labels is not available inside Julewire.ractor"
      end

      def reset!
        Core::ContextStore.reset_current!
      end

      def reset_facade! = reset!

      def emit_summary_record(scope)
        notify(:emit_record, payload: serialize_remote(summary_record_input(scope)))
      rescue StandardError => e
        @child_stats.message_dropped(e)
      end

      private

      def emit_non_standard_exception_summaries? = @emit_non_standard_exception_summaries

      def build_execution_boundary
        Core::Execution::Boundary.new(
          emit_summary_record: ->(scope) { emit_summary_record(scope) },
          summary_finalizer_failure: nil,
          emit_non_standard_exception_summaries: -> { emit_non_standard_exception_summaries? }
        )
      end

      def current_scope = Core::ContextStore.current.current_scope

      def summary_record_input(scope)
        scope.summary_record_input
      end

      def remote_emit_payload(record)
        serialize_remote(
          input: record,
          context: Core::ContextStore.current.context_hash,
          neutral: Core::ContextStore.current.neutral_hash,
          attributes: Core::ContextStore.current.attributes_hash,
          carry: Core::ContextStore.current.carry_hash,
          scope: scope_payload
        )
      end

      def serialize_remote(value)
        RemoteSerializer.call(value)
      end

      def scope_payload
        scope = Core::ContextStore.current.current_scope_or_snapshot
        return empty_scope_payload unless scope

        {
          execution: scope.execution_hash,
          neutral: scope.neutral_hash,
          attributes: scope.attributes_hash,
          carry: scope.carry_hash,
          labels: scope.labels_hash
        }
      end

      def empty_scope_payload
        { execution: {}, neutral: {}, attributes: {}, carry: {}, labels: {} }
      end

      def notify(command, payload:)
        @request_mutex.synchronize do
          @port.send({ command: command, payload: payload })
        end
        @child_stats.message_sent
      end

      def request(command, timeout:)
        reply = ::Ractor::Port.new
        @request_mutex.synchronize do
          @port.send({ command: command, payload: { timeout: timeout }, reply: reply })
        end
        @child_stats.request_sent
        wait_for_reply(reply, timeout)
      rescue StandardError => e
        @child_stats.request_failed(e)
      ensure
        close_reply(reply)
      end

      def effective_timeout(timeout)
        timeout.equal?(Core::UNSET) ? DEFAULT_REQUEST_TIMEOUT : timeout
      end

      def wait_for_reply(reply, timeout)
        response = if timeout.nil?
                     reply.receive
                   else
                     @timeout_scheduler.with_timeout(reply, timeout: timeout) { reply.receive }
                   end

        if response.equal?(REQUEST_TIMEOUT)
          @child_stats.request_timed_out
        else
          response
        end
      end

      def close_reply(reply)
        PortLifecycle.close(reply)
      end
    end
  end
end
