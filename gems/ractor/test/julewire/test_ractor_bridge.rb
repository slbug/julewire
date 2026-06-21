# frozen_string_literal: true

require "test_helper"
require "json"
require "stringio"

module Julewire
  class ReplyingPort
    attr_reader :messages

    def initialize(reply: "ok")
      @messages = []
      @reply = reply
    end

    def send(message)
      @messages << message
      message[:reply]&.send(@reply)
    end
  end

  class FailingPort
    def send(_message)
      raise "port failed"
    end
  end

  class ClosingPort
    def close
      raise "close failed"
    end
  end

  class FailingReply
    def send(_message)
      raise "reply failed"
    end
  end

  class ReplyProbe
    attr_reader :messages

    def initialize
      @messages = []
    end

    def send(message)
      @messages << message
    end
  end

  class NeverReplyingPort
    attr_reader :messages

    def initialize
      @messages = []
    end

    def send(message)
      @messages << message
    end
  end

  class QueueingOutput
    def initialize
      @queue = Queue.new
    end

    def write(value) # rubocop:disable Naming/PredicateMethod -- Output protocol uses truthy write results.
      @queue << value
      true
    end

    def pop = @queue.pop
  end

  class RactorPortOutput
    def initialize(port)
      @port = port
      @closed = false
    end

    def write(value) # rubocop:disable Naming/PredicateMethod -- Output protocol uses truthy write results.
      @port.send(value)
      true
    end

    def flush # rubocop:disable Naming/PredicateMethod -- Output protocol uses truthy flush results.
      @port.send(:flushed)
      true
    end

    def close # rubocop:disable Naming/PredicateMethod -- Output protocol uses truthy close results.
      @closed = true
      @port.send(:closed)
      true
    end

    def closed? = @closed
  end

  module DroppingRactorDestinationHelper
    def dropping_ractor_destination
      port = ::Ractor::Port.new
      drops = Queue.new
      destination = Julewire::Ractor::Destination.new(
        output: RactorPortOutput.new(port),
        on_drop: ->(reason, _metadata) { drops << reason }
      )
      [port, drops, destination]
    end
  end

  class SlowRactorPortOutput
    def initialize(write_port, sleep_seconds: 0.5)
      @write_port = write_port
      @sleep_seconds = sleep_seconds
    end

    def write(value) # rubocop:disable Naming/PredicateMethod -- Output protocol uses truthy write results.
      @write_port.send(value)
      sleep @sleep_seconds
      true
    end
  end

  class RejectingRactorPortOutput
    def initialize(write_port)
      @write_port = write_port
    end

    def write(value) # rubocop:disable Naming/PredicateMethod -- Output protocol uses truthy write results.
      @write_port.send(value)
      false
    end
  end

  class NonCopyableOutput
    def initialize
      @callback = -> {}
    end

    def write(_value) # rubocop:disable Naming/PredicateMethod -- Output protocol uses truthy write results.
      true
    end
  end

  class TestRemoteRuntime < Minitest::Test
    def test_remote_runtime_sends_emit_payload_to_parent_bridge
      port = ReplyingPort.new
      runtime = Julewire::Ractor::RemoteRuntime.new(port: port)

      runtime.context.add(request_id: "request-1")
      runtime.carry.add(http: { request_headers: { traceparent: "trace-1" } })
      result = runtime.emit(message: "done")
      message = port.messages.fetch(0)
      payload = message.fetch(:payload)

      assert_nil result
      assert_equal :emit, message.fetch(:command)
      refute_includes message, :reply
      assert_equal({ "message" => "done" }, payload.fetch(:input))
      assert_equal({ "request_id" => "request-1" }, payload.fetch(:context))
      assert_equal(
        { "http" => { "request_headers" => { "traceparent" => "trace-1" } } },
        payload.fetch(:carry)
      )
    end

    def test_remote_runtime_preserves_string_emit_payload
      port = ReplyingPort.new
      runtime = Julewire::Ractor::RemoteRuntime.new(port: port)

      runtime.emit("done")

      assert_equal "done", port.messages.fetch(0).fetch(:payload).fetch(:input)
    end

    def test_remote_runtime_evaluates_lazy_emit_blocks_before_sending
      port = ReplyingPort.new
      runtime = Julewire::Ractor::RemoteRuntime.new(port: port)

      runtime.emit { { message: "lazy" } }

      assert_equal({ "message" => "lazy" }, port.messages.fetch(0).fetch(:payload).fetch(:input))
    end

    def test_remote_runtime_sends_emit_without_level_payload_to_parent_bridge
      port = ReplyingPort.new
      runtime = Julewire::Ractor::RemoteRuntime.new(port: port)

      runtime.emit_without_level(severity: :debug, message: "debug")

      message = port.messages.fetch(0)

      assert_equal :emit_without_level, message.fetch(:command)
      assert_equal({ "severity" => "debug", "message" => "debug" }, message.fetch(:payload).fetch(:input))
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
      assert_equal "summary", payload.fetch("kind")
      assert_equal({ "processed" => 1 }, payload.fetch("payload"))
    end

    def test_remote_runtime_exposes_current_execution_predicate
      runtime = Julewire::Ractor::RemoteRuntime.new(port: ReplyingPort.new)

      refute_predicate runtime, :current_execution?
      runtime.with_execution(type: :job, emit_summary: false) do
        assert_predicate runtime, :current_execution?
      end
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

      assert_equal "summary", payload.fetch("kind")
      assert_equal "SystemExit", payload.dig("error", "class")
    end

    def test_remote_runtime_includes_scope_payload_and_can_skip_summary
      port = ReplyingPort.new
      runtime = Julewire::Ractor::RemoteRuntime.new(port: port)

      runtime.with_execution(type: :job, fields: { trace_id: "trace-1" }, emit_summary: false) do
        runtime.carry.add(http: { request_headers: { traceparent: "trace-1" } })
        runtime.emit(message: "scoped")
      end

      payload = port.messages.fetch(0).fetch(:payload)
      execution = payload.fetch(:scope).fetch("execution")
      carry = payload.fetch(:scope).fetch("carry")

      assert_equal 1, port.messages.length
      assert_equal "trace-1", execution.fetch("trace_id")
      assert_equal "job", execution.fetch("type")
      assert_equal "trace-1", carry.dig("http", "request_headers", "traceparent")
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
        attributes carry child_stats context current_execution current_execution? emit
        emit_without_level flush reset! reset_child_stats! start_execution
        summary with_execution
      ].each { assert_respond_to runtime, it }

      refute_respond_to runtime, :emit_envelope

      %i[after_fork! close config configure health labels].each do |method_name|
        assert_raises(Julewire::Core::Error) { runtime.public_send(method_name) }
      end
    end

    def test_remote_runtime_rejects_after_fork
      assert_remote_runtime_rejects(:after_fork!, "Julewire.after_fork!")
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
    def test_remote_runtime_request_failures_return_nil
      runtime = Julewire::Ractor::RemoteRuntime.new(port: FailingPort.new)

      assert_nil runtime.emit(message: "dropped")

      stats = runtime.child_stats

      assert_equal 1, stats.dig(:counts, :messages_dropped)
      assert_equal "RuntimeError", stats.fetch(:last_error_class)
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
    end

    def test_remote_runtime_lifecycle_request_times_out_without_reply
      port = NeverReplyingPort.new
      runtime = Julewire::Ractor::RemoteRuntime.new(port: port)

      assert_nil runtime.flush(timeout: 0.01)
      message = port.messages.fetch(0)
      stats = runtime.child_stats

      assert_equal :flush, message.fetch(:command)
      assert_equal({ timeout: 0.01 }, message.fetch(:payload))
      assert_respond_to message.fetch(:reply), :send
      assert_predicate message.fetch(:reply), :closed?
      assert_equal 1, stats.dig(:counts, :requests_sent)
      assert_equal 1, stats.dig(:counts, :requests_timed_out)
    end

    def test_remote_runtime_uses_default_flush_timeout_only_when_timeout_is_omitted
      port = ReplyingPort.new
      runtime = Julewire::Ractor::RemoteRuntime.new(port: port)

      assert_equal "ok", runtime.flush
      assert_equal "ok", runtime.flush(timeout: nil)

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
      runtime.reset!

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

  class TestRactorChildStats < Minitest::Test
    def test_child_stats_are_visible_inside_julewire_ractor
      with_experimental_ractor_warnings_suppressed do
        output = QueueingOutput.new
        Julewire.configure { configure_direct_destination(it, output: output) }

        stats = Julewire.ractor do
          Julewire.emit(message: "from child")
          Julewire::Ractor.child_stats
        end.value

        assert_equal "from child", JSON.parse(output.pop).fetch("message")
        assert_equal 1, stats.dig(:counts, :messages_sent)
        assert_equal 0, stats.dig(:counts, :messages_dropped)
      end
    end

    def test_child_stats_are_empty_outside_child_runtime
      assert_empty Julewire::Ractor.child_stats
    end

    def test_reset_child_stats_is_noop_outside_child_runtime
      assert_nil Julewire::Ractor.reset_child_stats!
    end

    def test_child_stats_delegate_to_child_like_runtime
      previous = Julewire::Core::RuntimeLocator.current
      runtime = Object.new
      runtime.define_singleton_method(:child_stats) { { counts: { messages_sent: 2 } } }
      runtime.define_singleton_method(:reset_child_stats!) { :reset }
      Julewire::Core::RuntimeLocator.current = runtime

      assert_equal({ counts: { messages_sent: 2 } }, Julewire::Ractor.child_stats)
      assert_equal :reset, Julewire::Ractor.reset_child_stats!
    ensure
      Julewire::Core::RuntimeLocator.current = previous if previous
    end

    private

    def with_experimental_ractor_warnings_suppressed(&)
      Julewire.enable_experimental_ractor!

      with_overridden_singleton_method(Warning, :warn, proc { |_message| }, &)
    end
  end

  class TestRactorDefaultDestinationFactory < Minitest::Test
    def test_default_destination_kind_uses_ractor_worker
      port = ::Ractor::Port.new
      Julewire::Ractor.enable_default_destination_workers!

      Julewire.configure do |config|
        config.destinations.use(:default, output: RactorPortOutput.new(port))
      end

      Julewire.emit(message: "default-worker")

      assert Julewire.flush(timeout: 1)
      assert_equal "default-worker", JSON.parse(port.receive).fetch("message")
      assert_equal :ok, Julewire.health.dig(:pipeline, :destinations, :default, :status)
    ensure
      Julewire.close(timeout: 1)
      Julewire::Testing.unregister_destination(:default)
      Julewire::Ractor::PortLifecycle.close(port) if port
    end
  end

  class TestRactorDestination < Minitest::Test
    include DroppingRactorDestinationHelper

    def test_ractor_destination_formats_encodes_and_writes_in_worker
      port = ::Ractor::Port.new
      destination = Julewire::Ractor::Destination.new(
        output: RactorPortOutput.new(port),
        close_output: true
      )
      Julewire.configure { it.destinations.add(destination) }

      Julewire.emit(message: "parallel", event: "ractor.destination")

      assert Julewire.flush(timeout: 1)

      messages = [port.receive, port.receive]
      record = JSON.parse(messages.find { it.is_a?(String) })

      assert_equal "parallel", record.fetch("message")
      assert_equal "ractor.destination", record.fetch("event")
      assert_includes messages, :flushed
      wait_until { destination.health.dig(:counts, :worker_accepted) == 1 }

      assert_equal 1, destination.health.dig(:counts, :worker_accepted)
    ensure
      destination&.close(timeout: 1)
      Julewire::Ractor::PortLifecycle.close(port) if port
    end

    def test_ractor_destination_drops_when_in_flight_queue_is_full
      write_port = ::Ractor::Port.new
      drops = Queue.new
      destination = Julewire::Ractor::Destination.new(
        output: SlowRactorPortOutput.new(write_port),
        max_queue: 1,
        request_timeout: 0.01,
        on_drop: ->(reason, _metadata) { drops << reason }
      )
      Julewire.configure { it.destinations.add(destination) }

      Julewire.emit(message: "first")
      first = write_port.receive

      assert_equal 1, destination.health.fetch(:in_flight)

      Julewire.emit(message: "second")

      assert Julewire.flush(timeout: 1)

      assert_equal "first", JSON.parse(first).fetch("message")
      assert_equal 1, destination.health.dig(:counts, :queue_full_dropped)
      assert_equal [:queue_full_dropped], nonblocking_queue_values(drops)
    ensure
      destination&.close(timeout: 1)
      Julewire::Ractor::PortLifecycle.close(write_port) if write_port
    end

    def test_ractor_destination_reports_worker_drops
      write_port = ::Ractor::Port.new
      destination = Julewire::Ractor::Destination.new(
        output: RejectingRactorPortOutput.new(write_port),
        request_timeout: 1
      )

      destination.emit(record(message: "rejected"))

      assert_equal "rejected", JSON.parse(write_port.receive).fetch("message")
      assert destination.flush(timeout: 1)
      wait_until { destination.health.dig(:counts, :worker_dropped) == 1 }
      health = destination.health

      assert_equal 1, health.dig(:counts, :worker_dropped)
      assert_equal :degraded, health.fetch(:status)
      assert_equal :output_rejected, health.dig(:worker, :last_loss, :reason)
    ensure
      destination&.close(timeout: 1)
      Julewire::Ractor::PortLifecycle.close(write_port) if write_port
    end

    def test_ractor_destination_uses_default_lifecycle_timeout
      port = ::Ractor::Port.new
      destination = Julewire::Ractor::Destination.new(output: RactorPortOutput.new(port))

      destination.emit(record(message: "default-timeout"))

      assert destination.flush
      assert_equal "default-timeout", JSON.parse(port.receive).fetch("message")
      assert destination.close
    ensure
      destination&.close(timeout: 1)
      Julewire::Ractor::PortLifecycle.close(port) if port
    end

    def test_ractor_destination_allows_unbounded_lifecycle_timeout
      port = ::Ractor::Port.new
      destination = Julewire::Ractor::Destination.new(
        output: RactorPortOutput.new(port),
        request_timeout: nil
      )

      destination.emit(record(message: "no-timeout"))

      assert destination.flush
      assert_equal "no-timeout", JSON.parse(port.receive).fetch("message")
    ensure
      destination&.close(timeout: 1)
      Julewire::Ractor::PortLifecycle.close(port) if port
    end

    def test_ractor_destination_drops_after_close
      port, drops, destination = dropping_ractor_destination

      assert destination.close(timeout: 1)

      destination.emit(record(message: "late"))
      health = destination.health

      assert_equal :closed, health.fetch(:status)
      assert_equal 1, health.dig(:counts, :closed_dropped)
      assert_equal :closed_dropped, health.dig(:last_loss, :reason)
      assert_equal [:closed_dropped], nonblocking_queue_values(drops)
    ensure
      destination&.close(timeout: 1)
      Julewire::Ractor::PortLifecycle.close(port) if port
    end

    def test_ractor_destination_rejects_lifecycle_requests_after_close
      port = ::Ractor::Port.new
      destination = Julewire::Ractor::Destination.new(output: RactorPortOutput.new(port))

      assert destination.close(timeout: 1)
      refute destination.flush(timeout: 1)
    ensure
      destination&.close(timeout: 1)
      Julewire::Ractor::PortLifecycle.close(port) if port
    end

    def test_ractor_destination_can_restart_after_fork
      port = ::Ractor::Port.new
      destination = Julewire::Ractor::Destination.new(output: RactorPortOutput.new(port))

      assert_same destination, destination.after_fork!

      destination.emit(record(message: "after-fork"))

      assert destination.flush(timeout: 1)

      assert_equal "after-fork", JSON.parse(port.receive).fetch("message")
    ensure
      destination&.close(timeout: 1)
      Julewire::Ractor::PortLifecycle.close(port) if port
    end

    def test_ractor_destination_rejects_non_copyable_collaborators
      error = assert_raises(ArgumentError) do
        Julewire::Ractor::Destination.new(output: NonCopyableOutput.new)
      end

      assert_match "ractor destination collaborators must be ractor-copyable or shareable", error.message
    end

    def test_ractor_destination_validates_names_before_starting_worker
      assert_raises(ArgumentError) { Julewire::Ractor::Destination.new(output: Object.new, name: nil) }
      assert_raises(ArgumentError) { Julewire::Ractor::Destination.new(output: Object.new, name: Object.new) }
      assert_raises(ArgumentError) { Julewire::Ractor::Destination.new(output: Object.new, name: :"") }
    end

    private

    def record(message:, payload: {})
      Julewire::Core::Records::Draft.build(
        { message: message, payload: payload },
        context: {},
        scope: nil
      ).to_record
    end

    def wait_until
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
      until yield
        flunk "condition did not become true" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        Thread.pass
      end
    end
  end

  class TestRactorDestinationConcurrentQueue < Minitest::Test
    def test_ractor_destination_reserves_queue_slots_across_concurrent_emitters
      accepted, dropped = exercise_concurrent_queue

      assert_includes %w[concurrent-0 concurrent-1], accepted
      assert_equal [:queue_full_dropped], dropped
      assert_equal 2, Array(accepted).size + dropped.size
    end

    def test_ractor_destination_queue_reservation_stress
      8.times do
        accepted, dropped = exercise_concurrent_queue(sleep_seconds: 0.02)

        assert_includes %w[concurrent-0 concurrent-1], accepted
        assert_equal [:queue_full_dropped], dropped
        assert_equal 2, Array(accepted).size + dropped.size
      end
    end

    private

    def concurrent_queue_destination(sleep_seconds:)
      write_port = ::Ractor::Port.new
      drops = Queue.new
      destination = Julewire::Ractor::Destination.new(
        output: SlowRactorPortOutput.new(write_port, sleep_seconds: sleep_seconds),
        max_queue: 1,
        request_timeout: 0.01,
        on_drop: ->(reason, _metadata) { drops << reason }
      )
      [write_port, drops, destination]
    end

    def start_concurrent_emitters(destination)
      ready = Queue.new
      start = Queue.new
      threads = Array.new(2) do |index|
        Thread.new do
          ready << true
          start.pop
          destination.emit(record(message: "concurrent-#{index}"))
        end
      end
      2.times { ready.pop }
      2.times { start << true }
      threads.each(&:join)
      threads
    end

    def exercise_concurrent_queue(sleep_seconds: 0.5)
      write_port, drops, destination = concurrent_queue_destination(sleep_seconds: sleep_seconds)
      threads = start_concurrent_emitters(destination)
      accepted = JSON.parse(write_port.receive).fetch("message")

      assert_equal 1, destination.health.dig(:counts, :queue_full_dropped)

      [accepted, nonblocking_queue_values(drops)]
    ensure
      threads&.each { |thread| thread.join(1) || thread.kill }
      destination&.close(timeout: 1)
      Julewire::Ractor::PortLifecycle.close(write_port) if write_port
    end

    def record(message:)
      Julewire::Core::Records::Draft.build(
        { message: message },
        context: {},
        scope: nil
      ).to_record
    end
  end

  class TestRactorDestinationFanout < Minitest::Test
    class DestinationProbe
      attr_reader :emitted, :forks, :health_calls, :name

      def initialize(name:, emit_error: nil, flush_result: true, close_result: true, health_error: nil, fork_error: nil)
        @name = name
        @emit_error = emit_error
        @flush_result = flush_result
        @close_result = close_result
        @health_error = health_error
        @fork_error = fork_error
        @emitted = []
        @forks = 0
        @health_calls = 0
      end

      def emit(record)
        raise @emit_error if @emit_error

        @emitted << record
        nil
      end

      def flush(timeout: nil)
        @flush_timeout = timeout
        @flush_result
      end

      def close(timeout: nil)
        @close_timeout = timeout
        @close_result
      end

      def after_fork!
        raise @fork_error if @fork_error

        @forks += 1
        self
      end

      def health
        @health_calls += 1
        raise @health_error if @health_error

        { status: :ok }
      end
    end

    def test_ractor_fanout_sends_record_to_each_worker_destination
      first_port = ::Ractor::Port.new
      second_port = ::Ractor::Port.new
      fanout = Julewire::Ractor.fanout(
        destinations: [
          { name: :first, output: RactorPortOutput.new(first_port) },
          { name: :second, output: RactorPortOutput.new(second_port) }
        ]
      )
      Julewire.configure { it.destinations.add(fanout) }

      Julewire.emit(message: "parallel-fanout", event: "ractor.fanout")

      assert fanout.flush(timeout: 1)

      assert_equal "parallel-fanout", port_record(first_port).fetch("message")
      assert_equal "parallel-fanout", port_record(second_port).fetch("message")
      assert_equal :ok, fanout.health.fetch(:status)
      assert_equal %i[first second], fanout.health.fetch(:destinations).keys
    ensure
      fanout&.close(timeout: 1)
      Julewire::Ractor::PortLifecycle.close(first_port) if first_port
      Julewire::Ractor::PortLifecycle.close(second_port) if second_port
    end

    def test_ractor_fanout_handles_destination_failures
      failures = Queue.new
      good = DestinationProbe.new(name: :good)
      bad = DestinationProbe.new(name: :bad, emit_error: RuntimeError.new("emit failed"))
      fanout = Julewire::Ractor::Fanout.new(
        destinations: [bad, good],
        on_failure: ->(error, **metadata) { failures << [error.class, metadata] }
      )
      record = build_record(message: "fanout")

      assert_nil fanout.emit(record)

      health = fanout.health

      assert_equal [record], good.emitted
      assert_equal :degraded, health.fetch(:status)
      assert_equal :emit, health.dig(:last_failure, :action)
      assert_equal :bad, health.dig(:last_failure, :destination)
      assert_equal RuntimeError, failures.pop.first
    end

    def test_ractor_fanout_contains_chaos_failures
      record = build_record(message: "fanout-chaos")

      Julewire::Testing::Chaos.assert_contained(self) do |error|
        bad = DestinationProbe.new(name: :bad, emit_error: error)
        fanout = Julewire::Ractor::Fanout.new(
          destinations: [bad],
          on_failure: Julewire::Testing::Chaos.raiser(error)
        )

        fanout.emit(record)
      end
    end

    def test_ractor_fanout_reports_lifecycle_and_health_failures
      bad_lifecycle = DestinationProbe.new(name: :bad_lifecycle, flush_result: false)
      bad_health = DestinationProbe.new(name: :bad_health, health_error: RuntimeError.new("health failed"))
      fanout = Julewire::Ractor::Fanout.new(destinations: [bad_lifecycle, bad_health])

      refute fanout.flush(timeout: 1)

      health = fanout.health

      assert_equal :degraded, health.fetch(:status)
      assert_equal :ractor_fanout_health, health.dig(:destinations, :bad_health, :phase)
    end

    def test_ractor_fanout_after_fork_forwards_and_contains_failures
      good = DestinationProbe.new(name: :good)
      bad = DestinationProbe.new(name: :bad, fork_error: RuntimeError.new("fork failed"))
      fanout = Julewire::Ractor::Fanout.new(destinations: [good, bad])

      assert_same fanout, fanout.after_fork!

      assert_equal 1, good.forks
      assert_equal :degraded, fanout.health.fetch(:status)
      assert_equal :after_fork, fanout.health.dig(:last_failure, :action)
    end

    def test_ractor_fanout_validates_options
      assert_raises(ArgumentError) { Julewire::Ractor::Fanout.new(destinations: []) }
      assert_raises(ArgumentError) { Julewire::Ractor::Fanout.new(destinations: [DestinationProbe.new(name: :ok)], name: nil) }
      assert_raises(ArgumentError) { Julewire::Ractor::Fanout.new(destinations: [DestinationProbe.new(name: :ok)], name: Object.new) }
      assert_raises(ArgumentError) { Julewire::Ractor::Fanout.new(destinations: [DestinationProbe.new(name: :ok)], name: "") }
    end

    private

    def build_record(message:)
      Julewire::Core::Records::Draft.build({ message: message }, context: {}, scope: nil).to_record
    end

    def port_record(port)
      messages = [port.receive, port.receive]
      JSON.parse(messages.find { it.is_a?(String) })
    end
  end

  class TestRactorDestinationSendError < Minitest::Test
    include DroppingRactorDestinationHelper

    def test_ractor_destination_drops_non_copyable_record_payload_values
      port, drops, destination = dropping_ractor_destination

      destination.emit(record(payload: { callback: proc {} }))
      health = destination.health

      assert_equal 1, health.dig(:counts, :send_error)
      assert_equal 0, health.fetch(:in_flight)
      assert_equal :send_error, health.dig(:last_loss, :reason)
      assert_equal :degraded, health.fetch(:status)
      assert_equal [:send_error], nonblocking_queue_values(drops)
    ensure
      destination&.close(timeout: 1)
      Julewire::Ractor::PortLifecycle.close(port) if port
    end

    private

    def record(payload:)
      Julewire::Core::Records::Draft.build(
        { message: "bad", payload: payload },
        context: {},
        scope: nil
      ).to_record
    end
  end

  class TestRactorBridge < Minitest::Test # rubocop:disable Metrics/ClassLength -- Bridge dispatch matrix.
    def test_ractor_bridge_dispatches_remote_emit_requests
      runtime = Object.new
      received = []
      runtime.define_singleton_method(:emit_envelope) do |input:, context:, carry:, attributes:, neutral:, scope:|
        received << [input, context, carry, attributes, neutral, scope]
        "formatted"
      end

      result = Julewire::Ractor::Bridge.__send__(
        :dispatch,
        runtime,
        remote_emit_message
      )

      assert_equal "formatted", result
      input, context, carry, attributes, neutral, scope = received.fetch(0)

      assert_equal remote_emit_arguments[0], input
      assert_equal remote_emit_arguments[1], context
      assert_equal remote_emit_arguments[2], carry
      assert_equal remote_emit_arguments[3], attributes
      assert_equal remote_emit_arguments[4], neutral
      assert_instance_of Julewire::Core::Execution::ScopeSnapshot, scope
      assert_empty scope.execution_hash
    end

    def test_ractor_bridge_dispatches_remote_emit_without_level_requests
      runtime = Object.new
      received = []
      runtime.define_singleton_method(:emit_envelope) do |input:, context:, carry:, attributes:, neutral:, scope:,
                                                          enforce_level: true|
        received << [input, context, carry, attributes, neutral, scope, enforce_level]
      end

      Julewire::Ractor::Bridge.__send__(
        :dispatch,
        runtime,
        remote_emit_message.merge(command: :emit_without_level)
      )

      refute received.fetch(0).fetch(6)
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
        {
          command: :emit_without_level,
          payload: { input: { severity: :debug, message: "debug" } }
        }
      )

      assert_equal "debug", JSON.parse(output.string).fetch("message")
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

    def test_runtime_emits_string_keyed_remote_summary_records
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
      record = JSON.parse(output.string)

      assert_equal "summary", record.fetch("kind")
      assert_equal "job.completed", record.fetch("event")
      assert_equal "request-1", record.dig("context", "request_id")
      assert_equal 1, record.dig("payload", "processed")
      assert_empty nonblocking_queue_values(failures)
    end

    def remote_emit_message
      {
        command: :emit,
        payload: {
          input: { message: "done" },
          context: { request_id: "r1" },
          carry: { http: { request_headers: { traceparent: "trace-1" } } },
          neutral: { "messaging.system" => "kafka" },
          attributes: {}
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

    def test_ractor_bridge_handles_replies_and_failures
      reply = ::Ractor::Port.new
      begin
        before = Julewire::Ractor.health
        runtime = Object.new
        runtime.define_singleton_method(:emit_envelope) { |**_| raise "boom" }

        Julewire::Ractor::Bridge.__send__(
          :handle_message,
          runtime,
          { command: :emit, payload: { input: {} }, reply: reply }
        )
        Julewire::Ractor::Bridge.__send__(:handle_message, runtime, { command: :unknown })

        assert_nil reply.receive
        assert_nil Julewire::Ractor::Bridge.__send__(:dispatch, runtime, { command: :unknown })

        after = Julewire::Ractor.health

        assert_equal before.fetch(:failure_count) + 1, after.fetch(:failure_count)
        assert_equal "RuntimeError", after.fetch(:last_error_class)
      ensure
        Julewire::Ractor::PortLifecycle.close(reply)
      end
    end

    def test_ractor_bridge_ignores_fake_reply_objects
      reply = ReplyProbe.new
      runtime = Object.new
      runtime.define_singleton_method(:emit_envelope) { |**_| raise "boom" }

      Julewire::Ractor::Bridge.__send__(
        :handle_message,
        runtime,
        { command: :emit, payload: { input: {} }, reply: reply }
      )
      Julewire::Ractor::Bridge.__send__(:handle_message, runtime, { command: :unknown })

      assert_empty reply.messages
      assert_nil Julewire::Ractor::Bridge.__send__(:dispatch, runtime, { command: :unknown })
    end

    def test_ractor_bridge_spawn_requires_bridge_runtime_methods
      runtime = Object.new
      Julewire.enable_experimental_ractor!

      error = assert_raises(ArgumentError) do
        Julewire::Ractor::Bridge.spawn(args: [], name: nil, runtime: runtime) do
          :unused
        end
      end

      assert_match(/missing: emit_envelope, emit_summary_record, flush/, error.message)
    end
  end

  class TestRactorBridgeLifecycle < Minitest::Test # rubocop:disable Metrics/ClassLength -- Bridge lifecycle matrix.
    cover Julewire::Ractor::Destination
    cover Julewire::Ractor::Fanout
    cover Julewire::Ractor::PortLifecycle

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
        @messages.pop
      end
    end

    class FakeRactor
      attr_reader :monitored_port

      def monitor(port)
        @monitored_port = port
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
      Julewire::Ractor::Bridge.__send__(
        :dispatch,
        runtime,
        { command: :close_runtime, payload: { timeout: 0.5 } }
      )

      assert_equal [[:flush, 0.25]], received
    end

    def test_ractor_bridge_start_bridge_warns_and_stops_on_receive_failure
      port = ReceivingPort.new

      warnings = run_bridge_and_capture_warnings(port)

      assert_equal ["julewire ractor bridge stopped: RuntimeError\n"], warnings
      assert_predicate port, :closed?
    end

    def test_ractor_bridge_threads_are_named_and_report_exceptions
      port = SequencePort.new({ command: :close })
      before = Julewire::Ractor.health

      thread = Julewire::Ractor::Bridge.__send__(:start_bridge, port: port, runtime: Object.new)

      assert_equal "julewire-ractor-bridge", thread.name
      assert thread.report_on_exception
      thread.value

      after = Julewire::Ractor.health

      assert after.fetch(:experimental)
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
      thread.value

      assert_instance_of ::Ractor::Port, ractor.monitored_port
    end

    def test_ractor_monitor_emits_exit_symbol
      # Canary for the Ruby monitor message shape used by BridgeThread.
      port = ::Ractor::Port.new
      ractor = ::Ractor.new { :done }
      ractor.monitor(port)

      selected, message = ::Ractor.select(port)

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

    def test_ractor_bridge_stops_on_monitor_messages
      port = ::Ractor::Port.new
      monitor_port = ::Ractor::Port.new

      thread = Julewire::Ractor::Bridge::BridgeThread.start(port: port, monitor_port: monitor_port) do
        raise "unexpected bridge message"
      end
      monitor_port.send(:aborted)

      thread.value

      refute_predicate thread, :alive?
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

    def test_remote_runtime_request_returns_nil_after_bridge_port_closes
      port = ReceivingPort.new

      run_bridge_and_capture_warnings(port)
      runtime = Julewire::Ractor::RemoteRuntime.new(port: port)

      assert_nil runtime.flush(timeout: 0.01)
    end

    def test_ractor_bridge_ignores_malformed_messages_without_stopping
      port = SequencePort.new(:malformed, { command: :close })

      warnings = run_bridge_and_capture_warnings(port)

      assert_empty warnings
    end

    def test_port_lifecycle_ignores_objects_without_close_and_already_closed_ports
      closed_port = Object.new
      closed_port.define_singleton_method(:close) { raise "already closed" }
      closed_port.define_singleton_method(:closed?) { true }

      assert_nil Julewire::Ractor::PortLifecycle.close(Object.new)
      assert_nil Julewire::Ractor::PortLifecycle.close(closed_port)
    end

    def test_remote_payload_extracts_input_and_scope
      assert_equal(
        "done",
        Julewire::Ractor::RemotePayload.extract("input" => "done").fetch(:input)
      )
      assert_equal(
        "symbol",
        Julewire::Ractor::RemotePayload.extract(input: "symbol").fetch(:input)
      )
      assert_instance_of(
        Julewire::Core::Execution::ScopeSnapshot,
        Julewire::Ractor::RemotePayload.extract(input: "symbol").fetch(:scope)
      )
    end

    def test_remote_payload_extracts_context_carry_and_rejects_non_hash_payloads
      context_payload = Julewire::Ractor::RemotePayload.extract("context" => { "request_id" => "r1" })

      assert_equal({}, context_payload.fetch(:input))
      assert_equal({ request_id: "r1" }, context_payload.fetch(:context))
      assert_equal({}, context_payload.fetch(:carry))
      assert_instance_of Julewire::Core::Execution::ScopeSnapshot, context_payload.fetch(:scope)

      carry_payload = Julewire::Ractor::RemotePayload.extract(
        "carry" => { "http" => { "request_headers" => { "traceparent" => "trace-1" } } }
      )

      assert_equal({ http: { request_headers: { traceparent: "trace-1" } } }, carry_payload.fetch(:carry))

      invalid_payload = Julewire::Ractor::RemotePayload.extract("not a hash")

      assert_equal({}, invalid_payload.fetch(:input))
      assert_equal({}, invalid_payload.fetch(:context))
      assert_equal({}, invalid_payload.fetch(:carry))
      assert_instance_of Julewire::Core::Execution::ScopeSnapshot, invalid_payload.fetch(:scope)
    end

    def test_reply_timeout_scheduler_sends_timeout_immediately_for_non_positive_timeout
      reply = ReplyProbe.new
      scheduler = Julewire::Ractor::ReplyTimeoutScheduler.new(timeout_value: :timeout)

      assert_nil scheduler.schedule(reply, timeout: 0)
      assert_equal [:timeout], reply.messages
    end

    def test_reply_timeout_scheduler_swallows_send_failures
      scheduler = Julewire::Ractor::ReplyTimeoutScheduler.new(timeout_value: :timeout)

      assert_nil scheduler.schedule(FailingReply.new, timeout: 0)
    end

    def test_port_lifecycle_swallows_close_failures
      assert_nil Julewire::Ractor::PortLifecycle.close(ClosingPort.new)
    end

    def test_ractor_bridge_warning_failures_are_swallowed
      with_overridden_singleton_method(Warning, :warn, proc { |_message| raise "warning failed" }) do
        assert_nil Julewire::Ractor::Bridge::BridgeThread.warn_bridge_stopped(RuntimeError.new)
      end
    end

    private

    def run_bridge_and_capture_warnings(port)
      warnings = []
      replacement = proc { warnings << it }

      with_overridden_singleton_method(Warning, :warn, replacement) do
        thread = Julewire::Ractor::Bridge.__send__(:start_bridge, port: port, runtime: Object.new)
        thread.value
      end

      warnings
    end
  end
end
