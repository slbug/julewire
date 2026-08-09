# frozen_string_literal: true

require "test_helper"
require_relative "support/bridge_test_values"

module Julewire
  class TestRactorBridge < Minitest::Test
    cover "Julewire::Ractor::Bridge.health"
    cover "Julewire::Ractor::Bridge.opt_in!"
    cover "Julewire.enable_experimental_ractor!"
    cover "Julewire::Ractor::Bridge.dispatch"
    cover "Julewire::Ractor::Bridge.dispatch_emit"
    cover "Julewire::Ractor::Bridge.enabled?"
    cover "Julewire::Ractor::Bridge.handle_message"
    cover "Julewire::Ractor::Bridge.reply_port?"
    cover "Julewire::Ractor::Bridge.reply_to"
    cover "Julewire::Ractor::Bridge.reset!"
    cover "Julewire::Ractor::Bridge.spawn_ractor"
    cover "Julewire::Ractor::Bridge.start"
    cover "Julewire::Ractor::Bridge.validate_message!"

    def test_ractor_bridge_dispatches_remote_emit_requests
      runtime = Object.new
      received = []
      runtime.define_singleton_method(:emit_envelope) do |input:, context:, carry:, attributes:, neutral:, scope:,
                                                          owned: false|
        received << [input, context, carry, attributes, neutral, scope, owned]
        "formatted"
      end

      result = Julewire::Ractor::Bridge.__send__(
        :dispatch,
        runtime,
        remote_emit_message
      )

      assert_equal "formatted", result
      assert_remote_emit_dispatch(received.fetch(0))
    end

    def test_ractor_bridge_dispatches_remote_emit_without_level_requests
      runtime = Object.new
      received = []
      runtime.define_singleton_method(:emit_envelope) do |input:, context:, carry:, attributes:, neutral:, scope:,
                                                          enforce_level: true, owned: false|
        received << [input, context, carry, attributes, neutral, scope, enforce_level, owned]
      end

      Julewire::Ractor::Bridge.__send__(
        :dispatch,
        runtime,
        remote_emit_message.merge(command: :emit_without_level)
      )

      assert_false received.fetch(0).fetch(6)
      assert_true received.fetch(0).fetch(7)
    end

    def test_runtime_dispatches_remote_emit_without_level_below_parent_threshold
      output = StringIO.new
      runtime = Julewire::Core::Runtime.new
      runtime.configure do |config|
        config.level = :fatal
        configure_direct_destination(config, output: output)
      end

      Julewire::Ractor::Bridge.__send__(
        :dispatch,
        runtime,
        remote_emit_message.merge(
          command: :emit_without_level,
          payload: remote_emit_message.fetch(:payload).merge(input: { severity: :debug, message: "debug" })
        )
      )

      assert_equal "debug", JSON.parse(output.string).fetch("message")
    end

    def assert_remote_emit_dispatch(received)
      input, context, carry, attributes, neutral, scope, owned = received

      assert_equal remote_emit_arguments[0], input
      assert_equal remote_emit_arguments[1], context
      assert_equal remote_emit_arguments[2], carry
      assert_equal remote_emit_arguments[3], attributes
      assert_equal remote_emit_arguments[4], neutral
      assert_true owned
      assert_instance_of Julewire::Core::Execution::ScopeSnapshot, scope
      assert_empty scope.execution_hash
    end

    def test_ractor_bridge_dispatches_summary_records
      runtime = Object.new
      received = []
      runtime.define_singleton_method(:emit_summary_record) do |scope|
        received << scope.owned_summary_record_input
      end

      Julewire::Ractor::Bridge.__send__(
        :dispatch,
        runtime,
        { command: :emit_record, payload: { event: "done" } }
      )

      assert_equal [{ event: "done" }], received
    end

    def test_runtime_rejects_string_keyed_owned_summary_records
      output = StringIO.new
      failures = Queue.new
      runtime = Julewire::Core::Runtime.new
      runtime.configure do |config|
        configure_direct_destination(config, output: output)
        config.on_failure = ->(error, _metadata) { failures << error }
      end
      summary_input = {
        "severity" => "info",
        "kind" => "summary",
        "event" => "job.completed",
        "source" => "julewire",
        "context" => { "request_id" => "request-1" },
        "payload" => { "processed" => 1 }
      }
      scope = Data.define(:owned_summary_record_input, :summary_record_input).new(summary_input, summary_input)

      runtime.emit_summary_record(scope)

      assert_empty output.string
      assert_instance_of TypeError, safe_queue_pop(failures)
    end

    def remote_emit_message
      {
        command: :emit,
        payload: {
          input: { message: "done" },
          context: { request_id: "r1" },
          carry: { http: { request_headers: { traceparent: "trace-1" } } },
          neutral: { "messaging.system": "kafka" },
          attributes: {},
          scope: { execution: {}, neutral: {}, attributes: {}, carry: {}, labels: {} }
        }
      }
    end

    def remote_emit_arguments
      [
        { message: "done" },
        { request_id: "r1" },
        { http: { request_headers: { traceparent: "trace-1" } } },
        {},
        { "messaging.system": "kafka" },
        {}
      ]
    end

    def test_remote_runtime_closes_reply_port_when_send_fails
      runtime_class = Class.new(Julewire::Ractor::RemoteRuntime) do
        attr_reader :closed_reply

        private

        def close_reply(reply)
          @closed_reply = reply
          super
        end
      end
      runtime = runtime_class.new(port: FailingPort.new)

      assert_nil runtime.flush(timeout: 0)
      assert_instance_of ::Ractor::Port, runtime.closed_reply
    end

    def test_ractor_bridge_records_runtime_failure_and_replies_nil
      reply = ::Ractor::Port.new
      begin
        before = Julewire::Ractor.health
        runtime = Object.new
        runtime.define_singleton_method(:emit_envelope) { |**_| raise "boom" }

        Julewire::Ractor::Bridge.__send__(
          :handle_message,
          runtime,
          remote_emit_message.merge(reply: reply)
        )

        assert_nil receive_ractor(reply)

        after = Julewire::Ractor.health

        assert_equal before.fetch(:failure_count) + 1, after.fetch(:failure_count)
        assert_equal "RuntimeError", after.fetch(:last_error_class)
      ensure
        Julewire::Ractor::PortLifecycle.close(reply)
      end
    end

    def test_ractor_bridge_sends_actual_reply_response
      reply = ::Ractor::Port.new

      Julewire::Ractor::Bridge.__send__(:reply_to, { reply: reply }, :ok)

      assert_equal :ok, receive_ractor(reply)
    ensure
      Julewire::Ractor::PortLifecycle.close(reply) if reply
    end

    def test_ractor_bridge_replies_to_hash_subclasses
      reply = ::Ractor::Port.new
      message = Class.new(Hash).new
      message[:reply] = reply

      Julewire::Ractor::Bridge.__send__(:reply_to, message, :ok)

      assert_equal :ok, receive_ractor(reply)
    ensure
      Julewire::Ractor::PortLifecycle.close(reply) if reply
    end

    def test_ractor_bridge_ignores_messages_without_a_reply_port
      before = Julewire::Ractor.health

      assert_nil Julewire::Ractor::Bridge.__send__(:reply_to, {}, :ok)
      assert_nil Julewire::Ractor::Bridge.__send__(:reply_to, { reply: nil }, :ok)

      assert_equal before.fetch(:failure_count), Julewire::Ractor.health.fetch(:failure_count)
    end

    def test_ractor_bridge_handle_message_replies_with_dispatch_result
      reply = ::Ractor::Port.new
      runtime = Object.new
      runtime.define_singleton_method(:flush) { |timeout:| [:flushed, timeout] }

      Julewire::Ractor::Bridge.__send__(
        :handle_message,
        runtime,
        { command: :flush, payload: { timeout: 0.25 }, reply: reply }
      )

      assert_equal [:flushed, 0.25], receive_ractor(reply)
    ensure
      Julewire::Ractor::PortLifecycle.close(reply) if reply
    end

    def test_ractor_bridge_records_reply_send_failures
      reply = ::Ractor::Port.new
      Julewire::Ractor::PortLifecycle.close(reply)
      before = Julewire::Ractor.health

      assert_nil Julewire::Ractor::Bridge.__send__(:reply_to, { reply: reply }, :ok)

      after = Julewire::Ractor.health

      assert_equal before.fetch(:failure_count) + 1, after.fetch(:failure_count)
      assert_equal "Ractor::ClosedError", after.fetch(:last_error_class)
    end

    def test_ractor_bridge_accepts_reply_port_subclasses
      reply = Class.new(::Ractor::Port).new

      assert_true Julewire::Ractor::Bridge.__send__(:reply_port?, reply)
    ensure
      Julewire::Ractor::PortLifecycle.close(reply) if reply
    end

    def test_ractor_bridge_records_invalid_reply_ports
      reply = ReplyProbe.new
      before = Julewire::Ractor.health

      assert_nil Julewire::Ractor::Bridge.__send__(:reply_to, { reply: reply }, :ok)

      assert_empty reply.messages
      assert_equal before.fetch(:failure_count) + 1, Julewire::Ractor.health.fetch(:failure_count)
      assert_equal "TypeError", Julewire::Ractor.health.fetch(:last_error_class)
      assert_equal "ractor bridge reply must be a Ractor::Port",
                   Julewire::Ractor.health.fetch(:last_error_message)
    end

    def test_ractor_bridge_records_non_hash_protocol_messages
      before = Julewire::Ractor.health

      assert_nil Julewire::Ractor::Bridge.__send__(:handle_message, Object.new, :malformed)

      after = Julewire::Ractor.health

      assert_equal before.fetch(:failure_count) + 1, after.fetch(:failure_count)
      assert_equal "TypeError", after.fetch(:last_error_class)
    end

    def test_ractor_bridge_rejects_missing_and_unknown_commands
      runtime = Object.new

      assert_raises(KeyError) { Julewire::Ractor::Bridge.__send__(:dispatch, runtime, {}) }
      error = assert_raises(ArgumentError) do
        Julewire::Ractor::Bridge.__send__(:dispatch, runtime, { command: :unknown })
      end

      assert_equal "unknown ractor bridge command: :unknown", error.message
    end

    def test_ractor_bridge_reset_clears_experimental_opt_in
      refute_predicate Julewire::Ractor::Bridge, :enabled?

      Julewire.enable_experimental_ractor!

      assert_predicate Julewire::Ractor::Bridge, :enabled?
      Julewire::Ractor::Bridge::Stats.message_failed(RuntimeError.new("old"))
      Julewire::Ractor::Bridge::Stats.message_received

      Julewire::Ractor::Bridge.reset!

      refute_predicate Julewire::Ractor::Bridge, :enabled?
      assert_equal 0, Julewire::Ractor.health.fetch(:failure_count)
      assert_equal 0, Julewire::Ractor.health.fetch(:messages)
      assert_false Julewire::Ractor.health.key?(:last_error_class)
    end

    def test_ractor_bridge_spawn_requires_bridge_runtime_methods
      runtime = Object.new
      Julewire.enable_experimental_ractor!

      error = assert_raises(ArgumentError) do
        Julewire::Ractor::Bridge.start(args: [], name: nil, runtime: runtime) do
          :unused
        end
      end

      assert_match(/missing: emit_envelope, emit_summary_record, flush/, error.message)
    end

    def test_ractor_bridge_start_wires_runtime_config_and_bridge_monitor
      runtime = Object.new
      config = Data.define(:emit_non_standard_exception_summaries).new(true)
      runtime.define_singleton_method(:config) { config }
      runtime.define_singleton_method(:emit_envelope) { |**| nil }
      runtime.define_singleton_method(:emit_summary_record) { |_scope| nil }
      runtime.define_singleton_method(:flush) { |**| true }
      fake_ractor = Object.new
      spawn_calls = []
      bridge_calls = []
      Julewire.enable_experimental_ractor!
      spawn_replacement = proc do |**arguments|
        spawn_calls << arguments
        fake_ractor
      end
      bridge_replacement = proc do |**arguments|
        bridge_calls << arguments
        :bridge_thread
      end

      result = with_overridden_singleton_method(Julewire::Ractor::Bridge, :spawn_ractor, spawn_replacement) do
        with_overridden_singleton_method(Julewire::Ractor::Bridge, :start_bridge, bridge_replacement) do
          Julewire::Ractor::Bridge.start(args: [:input], name: :worker, runtime: runtime) { :body }
        end
      end

      spawn_call = spawn_calls.fetch(0)

      assert_same fake_ractor, result
      assert_equal [:input], spawn_call.fetch(:args)
      assert_equal :worker, spawn_call.fetch(:name)
      assert_instance_of ::Ractor::Port, spawn_call.fetch(:port)
      assert_instance_of Proc, spawn_call.fetch(:body)
      assert_true spawn_call.fetch(:emit_non_standard_exception_summaries)
      assert_equal(
        [{ port: spawn_call.fetch(:port), runtime: runtime, ractor: fake_ractor }],
        bridge_calls
      )
    ensure
      Julewire::Ractor::PortLifecycle.close(spawn_calls&.dig(0, :port))
    end

    def test_ractor_bridge_spawn_wires_child_runtime_payload_and_close_message
      bridge_port = ReplyProbe.new
      body_calls = []
      new_calls = []
      fake_ractor = Object.new
      body = lambda do |*call_args|
        runtime = Julewire::Core::RuntimeLocator.current
        body_calls << {
          args: call_args,
          context: Julewire.context.to_h,
          emit_non_standard_exception_summaries: runtime.instance_variable_get(
            :@emit_non_standard_exception_summaries
          ),
          runtime_class: runtime.class
        }
      end
      Julewire.context.add(request_id: "request-1")
      envelope = Julewire::Core::Propagation.capture_local
      Julewire::Core::ContextStore.reset_current!
      previous_runtime = Julewire::Core::RuntimeLocator.current
      replacement = proc do |*arguments, name:, &block|
        new_calls << { arguments: arguments, name: name }
        block.call(*arguments)
        fake_ractor
      end

      result = with_overridden_singleton_method(::Ractor, :new, replacement) do
        Julewire::Ractor::Bridge.__send__(
          :spawn_ractor,
          args: %i[left right],
          name: "worker",
          port: bridge_port,
          envelope: envelope,
          body: body,
          emit_non_standard_exception_summaries: true
        )
      end

      assert_same fake_ractor, result
      assert_equal(
        [{ arguments: [bridge_port, envelope, body, true, :left, :right], name: "worker" }],
        new_calls
      )
      assert_equal(
        [
          {
            args: %i[left right],
            context: { request_id: "request-1" },
            emit_non_standard_exception_summaries: true,
            runtime_class: Julewire::Ractor::RemoteRuntime
          }
        ],
        body_calls
      )
      assert_equal [{ command: :close }], bridge_port.messages
    ensure
      Julewire::Core::RuntimeLocator.current = previous_runtime if defined?(previous_runtime)
    end

    def test_ractor_bridge_spawn_swallows_close_notification_failures
      bridge_port = FailingPort.new
      body_calls = []
      new_calls = []
      previous_runtime = Julewire::Core::RuntimeLocator.current
      replacement = proc do |*arguments, name:, &block|
        new_calls << name
        block.call(*arguments)
        :fake_ractor
      end

      result = with_overridden_singleton_method(::Ractor, :new, replacement) do
        Julewire::Ractor::Bridge.__send__(
          :spawn_ractor,
          args: [],
          name: "worker",
          port: bridge_port,
          envelope: {},
          body: -> { body_calls << :called },
          emit_non_standard_exception_summaries: false
        )
      end

      assert_equal :fake_ractor, result
      assert_equal ["worker"], new_calls
      assert_equal [:called], body_calls
    ensure
      Julewire::Core::RuntimeLocator.current = previous_runtime if defined?(previous_runtime)
    end
  end

  class TestRactorBridgeThreadStart < Minitest::Test
    cover "Julewire::Ractor::Bridge::BridgeThread.start"
    cover "Julewire::Ractor::Bridge::BridgeThread.monitor_message?"
    cover "Julewire::Ractor::Bridge::BridgeThread.receive_message"
    cover "Julewire::Ractor::Bridge::BridgeThread.run"

    class SequencePort
      def initialize(*messages)
        @messages = Queue.new
        messages.each { |message| @messages << message }
      end

      def receive = Timeout.timeout(1) { @messages.pop }
    end

    def test_start_accepts_missing_monitor_port
      port = SequencePort.new({ command: :close })
      previous_report_on_exception = Thread.report_on_exception
      Thread.report_on_exception = false

      thread = Timeout.timeout(0.1) do
        Julewire::Ractor::Bridge::BridgeThread.start(port: port) do
          raise "unexpected bridge message"
        end
      end

      assert_equal "julewire-ractor-bridge", thread.name
      assert_true thread.report_on_exception
      thread.report_on_exception = false

      assert_same thread, thread.join(0.1)
      assert_nil thread.value
      refute_predicate thread, :alive?
    ensure
      Thread.report_on_exception = previous_report_on_exception if defined?(previous_report_on_exception)
    end

    def test_start_stops_on_monitor_messages
      port = ::Ractor::Port.new
      monitor_port = ::Ractor::Port.new

      thread = Timeout.timeout(0.1) do
        Julewire::Ractor::Bridge::BridgeThread.start(port: port, monitor_port: monitor_port) do
          raise "unexpected bridge message"
        end
      end
      monitor_port.send(:aborted)

      thread.report_on_exception = false

      assert_same thread, thread.join(0.1)
      assert_nil thread.value
      refute_predicate thread, :alive?
    ensure
      Julewire::Ractor::PortLifecycle.close(port) if port
      Julewire::Ractor::PortLifecycle.close(monitor_port) if monitor_port
    end

    def test_start_reads_bridge_messages_while_monitoring_child_exit
      port = ::Ractor::Port.new
      monitor_port = ::Ractor::Port.new
      messages = Queue.new
      thread = Timeout.timeout(0.1) do
        Julewire::Ractor::Bridge::BridgeThread.start(port: port, monitor_port: monitor_port) do |message|
          messages << message
        end
      end

      port.send(:bridge_message)

      assert_equal :bridge_message, Timeout.timeout(0.1) { messages.pop }

      port.send({ command: :close })
      thread.report_on_exception = false

      assert_same thread, thread.join(0.1)
      assert_nil thread.value
    ensure
      Julewire::Ractor::PortLifecycle.close(port) if port
      Julewire::Ractor::PortLifecycle.close(monitor_port) if monitor_port
    end
  end

  class TestRactorBridgeLifecycle < Minitest::Test
    cover "Julewire::Ractor.health"
    cover "Julewire::Ractor::Bridge.after_fork!"
    cover "Julewire::Ractor::Bridge.before_fork!"
    cover "Julewire::Ractor::Bridge.dispatch"
    cover "Julewire::Ractor::Bridge.handle_message"
    cover "Julewire::Ractor::Bridge.monitor_ractor"
    cover "Julewire::Ractor::Bridge.reset!"
    cover "Julewire::Ractor::Bridge.start_bridge"
    cover "Julewire::Ractor::Bridge::BridgeThread.monitor_message?"
    cover "Julewire::Ractor::Bridge::BridgeThread.receive_message"
    cover "Julewire::Ractor::Bridge::BridgeThread.run"
    cover "Julewire::Ractor::Bridge::BridgeThread.close_message?"
    cover "Julewire::Ractor::Bridge::BridgeThread.warn_bridge_stopped"
    cover "Julewire::Ractor::RemoteRuntime#close"
    cover "Julewire::Ractor::RemoteRuntime#flush"
    cover "Julewire::Ractor::RemoteRuntime#request"
    class ReceivingPort
      attr_reader :closed

      def receive
        raise "receive failed"
      end

      def close
        @closed = true
      end

      def closed?
        @closed || false
      end

      def send(_message)
        raise "port closed" if closed?
      end
    end

    class SequencePort
      def initialize(*messages)
        @messages = Queue.new
        messages.each { @messages << it }
      end

      def receive
        Timeout.timeout(1) { @messages.pop }
      end
    end

    class FakeRactor
      attr_reader :monitored_port

      def monitor(port)
        @monitored_port = port
        :monitor_registered
      end
    end

    def test_remote_runtime_forwards_flush_requests_and_rejects_close
      port = ReplyingPort.new
      runtime = Julewire::Ractor::RemoteRuntime.new(port: port)

      assert_equal "ok", runtime.flush(timeout: 0.25)
      error = assert_raises(Julewire::Core::Error) { runtime.close(timeout: 0.5) }

      commands = port.messages.map { it.fetch(:command) }
      payloads = port.messages.map { it.fetch(:payload) }

      assert_match "Julewire.close is not available inside Julewire.ractor", error.message
      assert_equal %i[flush], commands
      assert_equal [{ timeout: 0.25 }], payloads
    end

    def test_ractor_bridge_dispatches_flush_requests
      runtime = Object.new
      received = []
      runtime.define_singleton_method(:flush) { |timeout: nil| received << [:flush, timeout] }
      runtime.define_singleton_method(:close) { |timeout: nil| received << [:unexpected_close, timeout] }

      Julewire::Ractor::Bridge.__send__(:dispatch, runtime, { command: :flush, payload: { timeout: 0.25 } })

      assert_equal [[:flush, 0.25]], received
    end

    def test_ractor_bridge_thread_run_accepts_missing_monitor_port
      port = SequencePort.new({ command: :close })

      assert_nil Julewire::Ractor::Bridge::BridgeThread.run(port: port, handler: lambda { |_message|
        raise "unexpected bridge message"
      })
    end

    def test_ractor_bridge_start_bridge_warns_and_stops_on_receive_failure
      port = ReceivingPort.new
      before = Julewire::Ractor.health

      warnings = run_bridge_and_capture_warnings(port)
      after = Julewire::Ractor.health

      assert_equal ["julewire ractor bridge stopped: RuntimeError\n"], warnings
      assert_predicate port, :closed?
      assert_equal before.fetch(:failure_count) + 1, after.fetch(:failure_count)
      assert_equal "RuntimeError", after.fetch(:last_error_class)
    end

    def test_ractor_bridge_threads_are_named_and_report_exceptions
      port = SequencePort.new({ command: :close })
      before = Julewire::Ractor.health

      thread = Julewire::Ractor::Bridge.__send__(:start_bridge, port: port, runtime: Object.new)

      assert_equal "julewire-ractor-bridge", thread.name
      assert_true thread.report_on_exception
      assert_bridge_thread_stops(thread)

      after = Julewire::Ractor.health

      assert_true after.fetch(:experimental)
      assert_equal before.fetch(:active_threads), after.fetch(:active_threads)
      assert_operator after.fetch(:messages), :>, before.fetch(:messages)
      assert_operator after.fetch(:started_threads), :>, before.fetch(:started_threads)
      assert_operator after.fetch(:stopped_threads), :>, before.fetch(:stopped_threads)
    end

    def test_ractor_bridge_monitors_child_ractor_when_available
      ractor = FakeRactor.new

      thread = Julewire::Ractor::Bridge.__send__(
        :start_bridge,
        port: ::Ractor::Port.new,
        runtime: Object.new,
        ractor: ractor
      )
      ractor.monitored_port.send(:exited)

      assert_bridge_thread_stops(thread)

      assert_instance_of ::Ractor::Port, ractor.monitored_port
    end

    def test_ractor_bridge_returns_monitor_port
      ractor = FakeRactor.new

      monitor_port = Julewire::Ractor::Bridge.__send__(:monitor_ractor, ractor)

      assert_instance_of ::Ractor::Port, monitor_port
      assert_same monitor_port, ractor.monitored_port
    ensure
      Julewire::Ractor::PortLifecycle.close(monitor_port) if monitor_port
    end

    def test_ractor_bridge_does_not_allocate_monitor_port_without_child_ractor
      calls = []
      replacement = proc {
        calls << :new
        raise "unexpected monitor port"
      }

      result = with_overridden_singleton_method(::Ractor::Port, :new, replacement) do
        Julewire::Ractor::Bridge.__send__(:monitor_ractor, nil)
      end

      assert_nil result
      assert_empty calls
    end

    def test_ractor_bridge_monitor_failures_disable_monitoring
      ractor = Object.new
      ractor.define_singleton_method(:monitor) { |_port| raise "monitor failed" }

      assert_nil Julewire::Ractor::Bridge.__send__(:monitor_ractor, ractor)
    end

    def test_ractor_bridge_does_not_pass_an_invalid_monitor_endpoint_to_ruby
      ractor = Object.new
      fatal = Class.new(Exception) # rubocop:disable Lint/InheritException
      ractor.define_singleton_method(:monitor) { |_port| raise fatal, "invalid monitor endpoint must not be forwarded" }

      result = with_overridden_singleton_method(::Ractor::Port, :new, proc { Object.new }) do
        Julewire::Ractor::Bridge.__send__(:monitor_ractor, ractor)
      end

      assert_nil result
    end

    def test_ractor_monitor_emits_exit_symbol
      # Canary for the Ruby monitor message shape used by BridgeThread.
      port = ::Ractor::Port.new
      ractor = ::Ractor.new { :done }
      ractor.monitor(port)

      selected, message = select_ractor(port)

      assert_same port, selected
      assert_equal :exited, message
    ensure
      begin
        ractor&.value
      rescue StandardError
        nil
      end
      begin
        port&.close
      rescue StandardError
        nil
      end
    end

    def test_ractor_bridge_reset_does_not_make_live_active_count_negative
      stats = Julewire::Ractor::Bridge::Stats
      baseline_active_threads = stats.health.fetch(:active_threads)

      stats.bridge_started
      stats.reset!
      stats.bridge_stopped

      assert_equal baseline_active_threads, stats.health.fetch(:active_threads)
    end

    def test_ractor_bridge_after_fork_clears_inherited_active_thread_count
      stats = Julewire::Ractor::Bridge::Stats

      stats.bridge_started
      Julewire::Ractor::Bridge.after_fork!

      assert_equal 0, stats.health.fetch(:active_threads)
      assert_equal 0, stats.health.fetch(:started_threads)
    end

    def test_ractor_bridge_before_fork_rejects_an_active_bridge
      stats = Julewire::Ractor::Bridge::Stats
      stats.bridge_started

      error = assert_raises(Julewire::Core::UnsafeForkError) do
        Julewire::Ractor::Bridge.before_fork!
      end

      assert_equal "cannot fork while 1 Julewire ractor bridge thread(s) are active", error.message
    ensure
      stats&.bridge_stopped
    end

    def test_ractor_bridge_before_fork_rejects_an_application_ractor
      ractor = ::Ractor.new { sleep 0.1 }

      error = assert_raises(Julewire::Core::UnsafeForkError) do
        Julewire::Ractor::Bridge.before_fork!
      end

      assert_equal "cannot fork while non-main Ractors are active", error.message
    ensure
      ractor&.value
    end

    def test_ractor_bridge_before_fork_accepts_the_main_ractor_alone
      assert_nil Julewire::Ractor::Bridge.before_fork!
    end

    def test_rejected_public_before_fork_resumes_a_quiesced_destination
      port = ::Ractor::Port.new
      destination = Julewire::Ractor::Destination.new(output: RactorPortOutput.new(port))
      Julewire.configure { it.destinations.add(destination) }
      application_ractor = ::Ractor.new { sleep 0.1 }

      assert_raises(Julewire::Core::UnsafeForkError) { Julewire.before_fork! }
      application_ractor.value

      Julewire.emit(message: "resumed")

      assert_true Julewire.flush(timeout: 1)
      messages = Array.new(3) { receive_ractor(port) }

      assert_equal "resumed", JSON.parse(messages.find { it.is_a?(String) }).fetch("message")
    ensure
      application_ractor&.value
      cleanup_ractor_destination(destination)
      Julewire::Ractor::PortLifecycle.close(port) if port
    end

    def test_remote_runtime_request_returns_nil_after_bridge_port_closes
      port = ReceivingPort.new

      run_bridge_and_capture_warnings(port)
      runtime = Julewire::Ractor::RemoteRuntime.new(port: port)

      assert_nil runtime.flush(timeout: 0.01)
      assert_equal 1, runtime.child_stats.dig(:counts, :requests_failed)
    end

    def test_ractor_bridge_records_malformed_messages_and_continues_to_close
      port = SequencePort.new(:malformed, { command: :close })
      before = Julewire::Ractor.health

      warnings = run_bridge_and_capture_warnings(port)

      assert_empty warnings
      assert_equal before.fetch(:failure_count) + 1, Julewire::Ractor.health.fetch(:failure_count)
      assert_equal "TypeError", Julewire::Ractor.health.fetch(:last_error_class)
    end

    def test_ractor_bridge_close_message_rejects_hash_without_command
      assert_false Julewire::Ractor::Bridge::BridgeThread.close_message?({})
      assert_false Julewire::Ractor::Bridge::BridgeThread.close_message?(command: :continue)
      assert_true Julewire::Ractor::Bridge::BridgeThread.close_message?(command: :close)
    end

    def test_ractor_bridge_warning_failures_are_swallowed
      with_overridden_singleton_method(Warning, :warn, proc { |_message| raise "warning failed" }) do
        assert_nil Julewire::Ractor::Bridge::BridgeThread.warn_bridge_stopped(RuntimeError.new)
      end
    end

    private

    def assert_bridge_thread_stops(thread)
      thread.report_on_exception = false

      safe_thread_value(thread, timeout: 0.1)
    end

    def run_bridge_and_capture_warnings(port)
      warnings = []
      replacement = proc { warnings << it }

      with_overridden_singleton_method(Warning, :warn, replacement) do
        thread = Julewire::Ractor::Bridge.__send__(:start_bridge, port: port, runtime: Object.new)

        assert_bridge_thread_stops(thread)
      end

      warnings
    end
  end
end
