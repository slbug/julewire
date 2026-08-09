# frozen_string_literal: true

require "test_helper"
require_relative "support/bridge_test_values"

module Julewire
  class TestRemoteRuntime < Minitest::Test
    cover "Julewire::Ractor::RemoteRuntime#after_fork!"
    cover "Julewire::Ractor::RemoteRuntime#attributes"
    cover "Julewire::Ractor::RemoteRuntime#build_execution_boundary"
    cover "Julewire::Ractor::RemoteRuntime#carry"
    cover "Julewire::Ractor::RemoteRuntime#close"
    cover "Julewire::Ractor::RemoteRuntime#config"
    cover "Julewire::Ractor::RemoteRuntime#configure"
    cover "Julewire::Ractor::RemoteRuntime#context"
    cover "Julewire::Ractor::RemoteRuntime#current_execution"
    cover "Julewire::Ractor::RemoteRuntime#current_execution?"
    cover "Julewire::Ractor::RemoteRuntime#current_scope"
    cover "Julewire::Ractor::RemoteRuntime#emit"
    cover "Julewire::Ractor::RemoteRuntime#emit_integration"
    cover "Julewire::Ractor::RemoteRuntime#emit_non_standard_exception_summaries?"
    cover "Julewire::Ractor::RemoteRuntime#emit_summary_record"
    cover "Julewire::Ractor::RemoteRuntime#emit_without_level"
    cover "Julewire::Ractor::RemoteRuntime#empty_scope_payload"
    cover "Julewire::Ractor::RemoteRuntime#health"
    cover "Julewire::Ractor::RemoteRuntime#initialize"
    cover "Julewire::Ractor::RemoteRuntime#labels"
    cover "Julewire::Ractor::RemoteRuntime#remote_emit"
    cover "Julewire::Ractor::RemoteRuntime#remote_emit_payload"
    cover "Julewire::Ractor::RemoteRuntime#scope_payload"
    cover "Julewire::Ractor::RemoteRuntime#serialize_remote"
    cover "Julewire::Ractor::RemoteRuntime#start_execution"
    cover "Julewire::Ractor::RemoteRuntime#summary"
    cover "Julewire::Ractor::RemoteRuntime#summary_record_input"
    cover "Julewire::Ractor::RemoteRuntime#with_execution"
    def test_remote_runtime_sends_emit_payload_to_parent_bridge
      port = ReplyingPort.new
      runtime = Julewire::Ractor::RemoteRuntime.new(port: port)

      runtime.context.add(request_id: "request-1")
      runtime.carry.add(http: { request_headers: { traceparent: "trace-1" } })
      runtime.attributes.add(worker: "ractor")
      Julewire::Core::Integration::Facade.add_neutral("messaging.system": "ractor")
      result = runtime.emit(message: "done")
      message = port.messages.fetch(0)
      payload = message.fetch(:payload)

      assert_nil result
      assert_equal :emit, message.fetch(:command)
      refute_includes message, :reply
      assert_equal({ message: "done" }, payload.fetch(:input))
      assert_equal({ request_id: "request-1" }, payload.fetch(:context))
      assert_equal(
        { http: { request_headers: { traceparent: "trace-1" } } },
        payload.fetch(:carry)
      )
      assert_equal({ worker: "ractor" }, payload.fetch(:attributes))
      assert_equal({ "messaging.system": "ractor" }, payload.fetch(:neutral))
      assert_equal(
        { execution: {}, neutral: {}, attributes: {}, carry: {}, labels: {} },
        payload.fetch(:scope)
      )
    end

    def test_remote_runtime_preserves_string_emit_payload
      port = ReplyingPort.new
      runtime = Julewire::Ractor::RemoteRuntime.new(port: port)

      runtime.emit("done")

      assert_equal({ message: "done" }, port.messages.fetch(0).fetch(:payload).fetch(:input))
    end

    def test_remote_runtime_field_only_emit_does_not_add_empty_message
      port = ReplyingPort.new
      runtime = Julewire::Ractor::RemoteRuntime.new(port: port)

      runtime.emit(event: "field.only")
      runtime.emit_without_level(severity: :debug)

      inputs = port.messages.map { it.fetch(:payload).fetch(:input) }

      assert_equal({ event: "field.only" }, inputs.fetch(0))
      assert_equal({ severity: "debug" }, inputs.fetch(1))
    end

    def test_remote_runtime_evaluates_lazy_emit_blocks_before_sending
      port = ReplyingPort.new
      runtime = Julewire::Ractor::RemoteRuntime.new(port: port)

      runtime.emit { { message: "lazy" } }

      assert_equal({ message: "lazy" }, port.messages.fetch(0).fetch(:payload).fetch(:input))
    end

    def test_remote_runtime_lazy_emit_preserves_eager_input_when_block_returns_nil
      port = ReplyingPort.new
      runtime = Julewire::Ractor::RemoteRuntime.new(port: port)

      runtime.emit(event: "lazy.keep") { nil }

      assert_equal({ event: "lazy.keep" }, port.messages.fetch(0).fetch(:payload).fetch(:input))
    end

    def test_remote_runtime_serializes_lazy_emit_input_wrappers
      port = ReplyingPort.new
      runtime = Julewire::Ractor::RemoteRuntime.new(port: port)
      input = Julewire::Core::Records::LazyEmitInput.with_severity(:warn, { message: "wrapped" })

      runtime.emit(input)

      assert_equal(
        { message: "wrapped", severity: "warn" },
        port.messages.fetch(0).fetch(:payload).fetch(:input)
      )
    end

    def test_remote_runtime_sends_emit_without_level_payload_to_parent_bridge
      port = ReplyingPort.new
      runtime = Julewire::Ractor::RemoteRuntime.new(port: port)

      runtime.emit_without_level(severity: :debug, message: "debug")

      message = port.messages.fetch(0)

      assert_equal :emit_without_level, message.fetch(:command)
      assert_equal({ severity: "debug", message: "debug" }, message.fetch(:payload).fetch(:input))
    end

    def test_remote_runtime_emit_without_level_preserves_record_and_lazy_block
      port = ReplyingPort.new
      runtime = Julewire::Ractor::RemoteRuntime.new(port: port)

      runtime.emit_without_level("debug message")
      runtime.emit_without_level(event: "lazy.debug") { { message: "from block" } }

      inputs = port.messages.map { it.fetch(:payload).fetch(:input) }

      assert_equal({ message: "debug message" }, inputs.fetch(0))
      assert_equal({ event: "lazy.debug", message: "from block" }, inputs.fetch(1))
    end

    def test_remote_runtime_uses_explicit_core_serializer_not_ractor_shadow
      shadow = Class.new do
        def self.call(_value)
          raise "ractor serializer shadow used"
        end
      end
      port = ReplyingPort.new
      runtime = Julewire::Ractor::RemoteRuntime.new(port: port)

      with_temporary_constant(Julewire::Ractor, :Serializer, shadow) do
        runtime.emit(message: "core serializer")
        runtime.with_execution(type: :job) { runtime.summary.add(processed: 1) }
      end

      assert_equal({ message: "core serializer" }, port.messages.fetch(0).fetch(:payload).fetch(:input))
      assert_equal "summary", port.messages.fetch(1).fetch(:payload).fetch(:kind)
    end

    def test_remote_runtime_emits_summary_records
      port = ReplyingPort.new
      runtime = Julewire::Ractor::RemoteRuntime.new(port: port)

      runtime.with_execution(type: :job) do
        runtime.summary.add(processed: 1)
      end

      message = port.messages.fetch(0)
      payload = message.fetch(:payload)

      assert_equal :emit_record, message.fetch(:command)
      refute_includes message, :reply
      assert_equal "summary", payload.fetch(:kind)
      assert_equal({ processed: 1 }, payload.fetch(:payload))
    end

    def test_remote_runtime_contains_summary_send_failures
      runtime = Julewire::Ractor::RemoteRuntime.new(port: FailingPort.new)

      result = runtime.with_execution(type: :job) do
        runtime.summary.add(processed: 1)
        :completed
      end

      assert_equal :completed, result
      assert_equal 1, runtime.child_stats.dig(:counts, :messages_dropped)
      assert_equal "RuntimeError", runtime.child_stats.fetch(:last_error_class)
    end

    def test_remote_runtime_exposes_current_execution_predicate
      runtime = Julewire::Ractor::RemoteRuntime.new(port: ReplyingPort.new)

      assert_nil runtime.current_execution
      refute_predicate runtime, :current_execution?
      runtime.with_execution(type: :job, emit_summary: false) do
        execution = runtime.current_execution

        assert_instance_of Julewire::Core::Execution::View, execution
        assert_equal "job", execution.type
        assert_true runtime.current_execution?
      end
      assert_nil runtime.current_execution
      refute_predicate runtime, :current_execution?
    end

    def test_remote_runtime_skips_non_standard_exception_summaries_by_default
      port = ReplyingPort.new
      runtime = Julewire::Ractor::RemoteRuntime.new(port: port)

      assert_raises(SystemExit) do
        runtime.with_execution(type: :job) { raise SystemExit, "stop" }
      end

      assert_empty port.messages
    end

    def test_remote_runtime_can_emit_non_standard_exception_summaries
      port = ReplyingPort.new
      runtime = Julewire::Ractor::RemoteRuntime.new(
        port: port,
        emit_non_standard_exception_summaries: true
      )

      assert_raises(SystemExit) do
        runtime.with_execution(type: :job) { raise SystemExit, "stop" }
      end

      payload = port.messages.fetch(0).fetch(:payload)

      assert_equal "summary", payload.fetch(:kind)
      assert_equal "SystemExit", payload.dig(:error, :class)
    end

    def test_remote_runtime_includes_scope_payload_and_can_skip_summary
      port = ReplyingPort.new
      runtime = Julewire::Ractor::RemoteRuntime.new(port: port)

      runtime.with_execution(type: :job, fields: { trace_id: "trace-1" }, emit_summary: false) do
        Julewire::Core::Integration::Facade.add_neutral("messaging.system": "ractor")
        runtime.attributes.add(worker: "ractor")
        runtime.carry.add(http: { request_headers: { traceparent: "trace-1" } })
        runtime.context.add(request_id: "request-1")
        runtime.emit(message: "scoped")
      end

      payload = port.messages.fetch(0).fetch(:payload)
      scope = payload.fetch(:scope)
      execution = scope.fetch(:execution)

      assert_equal 1, port.messages.length
      assert_equal "trace-1", execution.fetch(:trace_id)
      assert_equal "job", execution.fetch(:type)
      assert_equal(
        {
          attributes: { worker: "ractor" },
          carry: { http: { request_headers: { traceparent: "trace-1" } } },
          execution: execution,
          labels: {},
          neutral: { "messaging.system": "ractor" }
        },
        scope
      )
    end

    def test_remote_runtime_rejects_configuration_helpers
      runtime = Julewire::Ractor::RemoteRuntime.new(port: ReplyingPort.new)

      config_error = assert_raises(Julewire::Core::Error) { runtime.config }
      configure_error = assert_raises(Julewire::Core::Error) { runtime.configure }
      labels_error = assert_raises(Julewire::Core::Error) { runtime.labels }

      assert_match "Julewire.config", config_error.message
      assert_match "Julewire.configure", configure_error.message
      assert_match "Julewire.labels", labels_error.message
    end

    def test_remote_runtime_documents_child_facade_surface
      runtime = Julewire::Ractor::RemoteRuntime.new(port: ReplyingPort.new)

      %i[
        attributes carry child_stats context current_execution current_execution? emit emit_integration
        emit_without_level flush reset! reset_child_stats! reset_facade! start_execution
        summary with_execution
      ].each { assert_respond_to runtime, it }

      refute_respond_to runtime, :emit_envelope

      %i[after_fork! before_fork! close config configure health labels].each do |method_name|
        assert_raises(Julewire::Core::Error) { runtime.public_send(method_name) }
      end
    end

    def test_remote_runtime_rejects_after_fork
      assert_remote_runtime_rejects(:after_fork!, "Julewire.after_fork!")
    end

    def test_remote_runtime_rejects_before_fork
      assert_remote_runtime_rejects(:before_fork!, "Julewire.before_fork!")
    end

    def test_remote_runtime_rejects_health
      assert_remote_runtime_rejects(:health, "Julewire.health")
    end

    def assert_remote_runtime_rejects(method_name, message)
      runtime = Julewire::Ractor::RemoteRuntime.new(port: ReplyingPort.new)

      error = assert_raises(Julewire::Core::Error) { runtime.public_send(method_name) }

      assert_match message, error.message
    end
  end

  class TestRemoteRuntimeLifecycle < Minitest::Test
    cover "Julewire::Ractor::RemoteRuntime#child_stats"
    cover "Julewire::Ractor::RemoteRuntime#close_reply"
    cover "Julewire::Ractor::RemoteRuntime#effective_timeout"
    cover "Julewire::Ractor::RemoteRuntime#emit"
    cover "Julewire::Ractor::RemoteRuntime#flush"
    cover "Julewire::Ractor::RemoteRuntime#initialize"
    cover "Julewire::Ractor::RemoteRuntime#remote_emit"
    cover "Julewire::Ractor::RemoteRuntime#request"
    cover "Julewire::Ractor::RemoteRuntime#reset!"
    cover "Julewire::Ractor::RemoteRuntime#reset_child_stats!"
    cover "Julewire::Ractor::RemoteRuntime#reset_facade!"
    cover "Julewire::Ractor::RemoteRuntime#wait_for_reply"
    def test_remote_runtime_emit_send_failures_return_nil
      runtime = Julewire::Ractor::RemoteRuntime.new(port: FailingPort.new)

      assert_nil runtime.emit(message: "dropped")

      stats = runtime.child_stats

      assert_equal 1, stats.dig(:counts, :messages_dropped)
      assert_equal "RuntimeError", stats.fetch(:last_error_class)
    end

    def test_remote_runtime_scalar_emit_stringifies_message_payload
      port = ReplyingPort.new
      runtime = Julewire::Ractor::RemoteRuntime.new(port: port)
      scalar = Object.new
      scalar.define_singleton_method(:to_s) { "scalar-message" }

      runtime.emit(scalar)

      assert_equal "scalar-message", port.messages.fetch(0).dig(:payload, :input, :message)
    end

    def test_remote_runtime_emit_treats_hash_subclasses_as_hashes
      port = ReplyingPort.new
      runtime = Julewire::Ractor::RemoteRuntime.new(port: port)
      input = Class.new(Hash).new
      input[:message] = "hash-subclass"

      runtime.emit(input)

      assert_equal "hash-subclass", port.messages.fetch(0).dig(:payload, :input, :message)
    end

    def test_remote_runtime_lifecycle_send_failure_records_failure_and_closes_reply
      port = RequestFailingPort.new
      runtime = Julewire::Ractor::RemoteRuntime.new(port: port)

      assert_nil runtime.flush(timeout: 0.1)

      stats = runtime.child_stats

      assert_equal 1, stats.dig(:counts, :requests_failed)
      assert_equal "RuntimeError", stats.fetch(:last_error_class)
      assert_predicate port.reply, :closed?
    end

    def test_remote_runtime_child_stats_can_be_reset
      runtime = Julewire::Ractor::RemoteRuntime.new(port: FailingPort.new)

      runtime.emit(message: "dropped")
      runtime.reset_child_stats!

      stats = runtime.child_stats

      assert_equal 0, stats.dig(:counts, :messages_dropped)
      assert_nil stats[:last_error_class]
    end

    def test_remote_runtime_uses_separate_reply_ports_for_lifecycle_requests
      port = ReplyingPort.new
      runtime = Julewire::Ractor::RemoteRuntime.new(port: port)

      assert_equal "ok", runtime.flush(timeout: 0.1)
      assert_equal "ok", runtime.flush(timeout: 0.2)

      replies = port.messages.map { it.fetch(:reply) }

      refute_same replies.first, replies.last
      assert_true replies.all?(&:closed?)
      assert_equal 2, runtime.child_stats.dig(:counts, :requests_sent)
    end

    def test_remote_runtime_counts_timeout_from_its_default_scheduler
      port = NeverReplyingPort.new
      runtime = Julewire::Ractor::RemoteRuntime.new(port: port)

      assert_nil Timeout.timeout(0.1) { runtime.flush(timeout: 0) }

      assert_equal 1, runtime.child_stats.dig(:counts, :requests_timed_out)
    end

    def test_remote_runtime_uses_default_flush_timeout_only_when_timeout_is_omitted
      port = ReplyingPort.new
      runtime = Julewire::Ractor::RemoteRuntime.new(port: port)

      response = Timeout.timeout(0.1) do
        [runtime.flush, runtime.flush(timeout: nil)]
      end

      assert_equal %w[ok ok], response

      timeouts = port.messages.map { it.dig(:payload, :timeout) }

      assert_equal [1, nil], timeouts
    end

    def test_remote_runtime_cancels_reply_timeout_after_early_lifecycle_reply
      wait_for_no_reply_timeout_threads
      runtime = Julewire::Ractor::RemoteRuntime.new(port: ReplyingPort.new)

      20.times do
        assert_equal "ok", runtime.flush(timeout: 0.5)
      end

      wait_for_no_reply_timeout_threads

      assert_equal 0, reply_timeout_thread_count
    end

    def test_remote_runtime_reset_clears_local_context
      runtime = Julewire::Ractor::RemoteRuntime.new(port: ReplyingPort.new)

      runtime.context.add(worker: "ractor")
      runtime.reset_facade!

      assert_empty runtime.context.to_h
    end

    def test_remote_runtime_flush_rejects_invalid_timeouts_before_ipc
      runtime = Julewire::Ractor::RemoteRuntime.new(port: Object.new)

      error = assert_raises(ArgumentError) { runtime.flush(timeout: -1) }

      assert_match "timeout must be nil or a non-negative finite Numeric", error.message
    end

    private

    def wait_for_no_reply_timeout_threads
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
      until reply_timeout_thread_count.zero?
        flunk "reply timeout thread did not exit" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        Thread.pass
      end
    end

    def reply_timeout_thread_count
      Thread.list.count do |thread|
        thread.name == Julewire::Ractor::ReplyTimeoutScheduler::THREAD_NAME && thread.alive?
      end
    end
  end
end
