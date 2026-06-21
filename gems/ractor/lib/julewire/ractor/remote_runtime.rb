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

      def remote_emit(command, record, fields, &)
        record = Core.emit_input(record, fields)
        record = Core::Records::LazyEmitInput.call(record, &) if block_given?
        record = record.to_h if Core::Records::LazyEmitInput.input?(record)
        notify(command, payload: remote_emit_payload(record))
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

      def emit_summary_record(scope)
        notify(:emit_record, payload: Core::Serialization::Serializer.call(summary_record_input(scope)))
      end

      private

      def emit_non_standard_exception_summaries? = @emit_non_standard_exception_summaries

      def summary_finalizer_failure
        @summary_finalizer_failure ||= ->(_error) {}
      end

      def build_execution_boundary
        Core::Execution::Boundary.new(
          emit_summary_record: ->(scope) { emit_summary_record(scope) },
          summary_finalizer_failure: summary_finalizer_failure,
          emit_non_standard_exception_summaries: -> { emit_non_standard_exception_summaries? }
        )
      end

      def current_scope = Core::ContextStore.current.current_scope

      def summary_record_input(scope)
        scope.summary_record_input
      end

      def remote_emit_payload(record)
        {
          input: Core::Serialization::Serializer.call(record),
          context: Core::Serialization::Serializer.call(Core::ContextStore.current.context_hash),
          neutral: Core::Serialization::Serializer.call(Core::ContextStore.current.neutral_hash),
          attributes: Core::Serialization::Serializer.call(Core::ContextStore.current.attributes_hash),
          carry: Core::Serialization::Serializer.call(Core::ContextStore.current.carry_hash),
          scope: Core::Serialization::Serializer.call(scope_payload)
        }
      end

      def scope_payload
        scope = Core::ContextStore.current.current_scope_or_snapshot
        return {} unless scope

        {
          execution: scope.execution_hash,
          neutral: scope.neutral_hash,
          attributes: scope.attributes_hash,
          carry: scope.carry_hash,
          labels: scope.labels_hash
        }
      end

      def notify(command, payload:)
        @request_mutex.synchronize do
          @port.send({ command: command, payload: payload })
        end
        @child_stats.message_sent
        nil
      rescue StandardError => e
        @child_stats.message_dropped(e)
        nil
      end

      def request(command, timeout:)
        reply = ::Ractor::Port.new
        waiting_for_reply = false
        @request_mutex.synchronize do
          @port.send({ command: command, payload: { timeout: timeout }, reply: reply })
        end
        @child_stats.request_sent
        waiting_for_reply = true
        wait_for_reply(reply, timeout)
      rescue StandardError => e
        @child_stats.request_failed(e)
        nil
      ensure
        close_reply(reply) if reply && !waiting_for_reply
      end

      def effective_timeout(timeout)
        timeout.equal?(Core::UNSET) ? DEFAULT_REQUEST_TIMEOUT : timeout
      end

      def wait_for_reply(reply, timeout)
        timeout_token = @timeout_scheduler.schedule(reply, timeout: timeout) if timeout
        response = reply.receive

        if response.equal?(REQUEST_TIMEOUT)
          @child_stats.request_timed_out
          nil
        else
          response
        end
      rescue StandardError
        nil
      ensure
        @timeout_scheduler.cancel(timeout_token)
        close_reply(reply)
      end

      def close_reply(reply)
        PortLifecycle.close(reply)
      end
    end
  end
end
