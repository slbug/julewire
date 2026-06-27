# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestRactorDestinationWorker < Minitest::Test
    cover "Julewire::Ractor::DestinationWorker*"
    cover "Julewire::Ractor::DestinationWorker.run"
    cover "Julewire::Ractor::DestinationWorker#run"
    cover "Julewire::Ractor::DestinationWorker#record_write_step_failure"
    cover Julewire::Ractor::PortLifecycle

    def test_worker_writes_record_reports_ack_and_exposes_health
      output = WorkerOutput.new
      reply = ::Ractor::Port.new

      run_worker(
        output: output,
        encoder: ->(record) { record.fetch(:message) },
        commands: emit_health_and_close_commands(message: "ok", reply: reply)
      ) do |ack_port|
        health = receive_ractor(reply)

        assert_equal [{ degradation_marker: nil, event: :ack, status: :accepted }], receive_messages(ack_port, 1)
        assert_equal 1, health.dig(:counts, :received)
        assert_equal 1, health.dig(:counts, :formatted)
        assert_equal 1, health.dig(:counts, :output_accepted)
      end

      assert_equal ["ok"], output.written
      assert_equal %i[write closed? close], output.calls
    ensure
      Julewire::Ractor::PortLifecycle.close(reply) if reply
    end

    def test_worker_reports_formatter_failures_as_dropped_records
      assert_worker_transform_failure(
        transform: :formatter,
        callable: ->(_record) { raise "format failed" },
        counter: :formatter_error,
        phase: :formatter
      )
    end

    def test_worker_reports_encoder_failures_as_dropped_records
      assert_worker_transform_failure(
        transform: :encoder,
        callable: ->(_record) { raise "encode failed" },
        counter: :encode_error,
        phase: :encode
      )
    end

    def test_worker_drops_oversized_records_without_writing_the_output
      output = WorkerOutput.new
      reply = ::Ractor::Port.new

      run_worker(
        output: output,
        encoder: ->(_record) { "too large" },
        max_record_bytes: 1,
        commands: [{ command: :emit, degradation_marker: nil, record: { message: "oversized" } },
                   { command: :health, reply: reply },
                   { command: :close_worker }]
      ) do |ack_port|
        health = receive_ractor(reply)

        assert_equal [{ degradation_marker: nil, event: :ack, status: :dropped }], receive_messages(ack_port, 1)
        assert_equal 1, health.dig(:counts, :record_too_large)
        assert_equal :record_too_large, health.dig(:last_loss, :reason)
        assert_equal 9, health.dig(:last_loss, :bytesize)
        assert_equal 1, health.dig(:last_loss, :max_record_bytes)
        refute_includes health.fetch(:last_loss), :record
      end

      assert_empty output.written
    ensure
      Julewire::Ractor::PortLifecycle.close(reply) if reply
    end

    def test_worker_reports_output_rejection_and_exception_as_dropped_records
      rejection_reply = ::Ractor::Port.new
      exception_reply = ::Ractor::Port.new
      rejected_output = WorkerOutput.new(write_result: false)
      failing_output = WorkerOutput.new(write_error: RuntimeError.new("write failed"))

      run_worker(
        output: rejected_output,
        encoder: ->(record) { record.fetch(:message) },
        commands: emit_health_and_close_commands(message: "rejected", reply: rejection_reply)
      ) do |ack_port|
        health = receive_ractor(rejection_reply)

        assert_equal [{ degradation_marker: nil, event: :ack, status: :dropped }], receive_messages(ack_port, 1)
        assert_equal 1, health.dig(:counts, :output_rejected)
        assert_equal :output_rejected, health.dig(:last_loss, :reason)
      end

      run_worker(
        output: failing_output,
        encoder: ->(record) { record.fetch(:message) },
        commands: emit_health_and_close_commands(message: "boom", reply: exception_reply)
      ) do |ack_port|
        health = receive_ractor(exception_reply)

        assert_equal [{ degradation_marker: nil, event: :ack, status: :dropped }], receive_messages(ack_port, 1)
        assert_equal 1, health.dig(:counts, :output_exception)
        assert_equal :output, health.dig(:last_failure, :phase)
        assert_equal :write, health.dig(:last_failure, :action)
        assert_equal failing_output.class.name, health.dig(:last_failure, :output_class)
        refute_includes health.fetch(:last_failure), :record
        refute_includes health.fetch(:counts), :failures
      end
    ensure
      Julewire::Ractor::PortLifecycle.close(rejection_reply) if rejection_reply
      Julewire::Ractor::PortLifecycle.close(exception_reply) if exception_reply
    end

    def test_worker_recovers_current_health_without_erasing_failure_history
      output = RecoveringWorkerOutput.new
      first_flush_reply = ::Ractor::Port.new
      second_flush_reply = ::Ractor::Port.new
      write_health_reply = ::Ractor::Port.new
      health_reply = ::Ractor::Port.new

      run_worker(
        output: output,
        encoder: ->(record) { record.fetch(:message) },
        commands: [
          { command: :emit, degradation_marker: nil, record: { message: "failed" } },
          { command: :emit, degradation_marker: :parent_degradation, record: { message: "accepted" } },
          { command: :health, reply: write_health_reply },
          { command: :flush, reply: first_flush_reply },
          { command: :flush, reply: second_flush_reply },
          { command: :health, reply: health_reply },
          { command: :close_worker }
        ]
      ) do |ack_port|
        assert_equal(
          [
            { degradation_marker: nil, event: :ack, status: :dropped },
            { degradation_marker: :parent_degradation, event: :ack, status: :accepted }
          ],
          receive_messages(ack_port, 2)
        )
        write_health = receive_ractor(write_health_reply)

        assert_equal :ok, write_health.fetch(:status)
        assert_equal :output_exception, write_health.dig(:last_loss, :reason)
        assert_false receive_ractor(first_flush_reply)
        assert_true receive_ractor(second_flush_reply)
        health = receive_ractor(health_reply)

        assert_equal :ok, health.fetch(:status)
        assert_equal :output_lifecycle, health.dig(:last_failure, :phase)
        assert_equal :flush, health.dig(:last_failure, :action)
        assert_equal :output_exception, health.dig(:last_loss, :reason)
        assert_equal ["accepted"], output.written
      end
    ensure
      [first_flush_reply, second_flush_reply, write_health_reply, health_reply].compact.each do |port|
        Julewire::Ractor::PortLifecycle.close(port)
      end
    end

    def test_worker_answers_flush_and_health_with_real_reply_ports
      output = WorkerOutput.new
      flush_reply = Class.new(::Ractor::Port).new
      health_reply = ::Ractor::Port.new

      run_worker(
        output: output,
        commands: [{ command: :flush, reply: flush_reply }, { command: :health, reply: health_reply },
                   { command: :close_worker }]
      ) do
        assert_true receive_ractor(flush_reply)
        assert_equal :ok, receive_ractor(health_reply).fetch(:status)
      end

      assert_equal %i[flush closed? close], output.calls
    ensure
      Julewire::Ractor::PortLifecycle.close(flush_reply) if flush_reply
      Julewire::Ractor::PortLifecycle.close(health_reply) if health_reply
    end

    def test_worker_reports_rejected_and_failed_flushes_without_stopping
      rejected_reply = ::Ractor::Port.new
      nil_reply = ::Ractor::Port.new
      false_like_reply = ::Ractor::Port.new
      failed_reply = ::Ractor::Port.new
      rejection_health_reply = ::Ractor::Port.new
      failure_health_reply = ::Ractor::Port.new

      run_worker(
        output: WorkerOutput.new(flush_result: false),
        commands: [{ command: :flush, reply: rejected_reply }, { command: :health, reply: rejection_health_reply },
                   { command: :close_worker }]
      ) do |_ack_port|
        assert_false receive_ractor(rejected_reply)
        assert_equal :ok, receive_ractor(rejection_health_reply).fetch(:status)
      end

      run_worker(
        output: WorkerOutput.new(flush_result: nil),
        commands: [{ command: :flush, reply: nil_reply }, { command: :close_worker }]
      ) do |_ack_port|
        assert_true receive_ractor(nil_reply)
      end

      run_worker(
        output: WorkerOutput.new(flush_result: FalseLike.new),
        commands: [{ command: :flush, reply: false_like_reply }, { command: :close_worker }]
      ) do |_ack_port|
        assert_false receive_ractor(false_like_reply)
      end

      run_worker(
        output: WorkerOutput.new(flush_error: RuntimeError.new("flush failed")),
        commands: [{ command: :flush, reply: failed_reply }, { command: :health, reply: failure_health_reply },
                   { command: :close_worker }]
      ) do |_ack_port|
        assert_false receive_ractor(failed_reply)
        health = receive_ractor(failure_health_reply)

        assert_equal :degraded, health.fetch(:status)
        assert_equal :output_lifecycle, health.dig(:last_failure, :phase)
        assert_equal :flush, health.dig(:last_failure, :action)
        assert_equal "RuntimeError", health.dig(:last_failure, :class)
      end
    ensure
      [
        rejected_reply,
        nil_reply,
        false_like_reply,
        failed_reply,
        rejection_health_reply,
        failure_health_reply
      ].compact.each do |port|
        Julewire::Ractor::PortLifecycle.close(port)
      end
    end

    def test_worker_close_uses_owned_output_and_returns_its_result
      output = WorkerOutput.new(close_result: false)

      assert_worker_close(output: output, expected: false)

      assert_equal %i[closed? close closed? close], output.calls
    end

    def test_worker_close_accepts_a_nil_output_result
      output = WorkerOutput.new(close_result: nil)

      assert_worker_close(output: output, expected: true)

      assert_equal %i[closed? close closed?], output.calls
    end

    def test_worker_close_rejects_false_like_output_results
      output = WorkerOutput.new(close_result: FalseLike.new)

      assert_worker_close(output: output, expected: false)
    end

    def test_worker_close_flushes_unowned_output_without_closing_it
      output = WorkerOutput.new

      assert_worker_close(output: output, expected: true, close_output: false)

      assert_equal %i[closed? flush closed?], output.calls
    end

    def test_worker_close_accepts_nil_and_rejects_false_like_unowned_flush_results
      nil_reply = ::Ractor::Port.new
      false_like_reply = ::Ractor::Port.new

      run_worker(
        output: WorkerOutput.new(flush_result: nil),
        close_output: false,
        commands: [{ command: :close, reply: nil_reply }]
      ) do |_ack_port|
        assert_true receive_ractor(nil_reply)
      end

      run_worker(
        output: WorkerOutput.new(flush_result: FalseLike.new),
        close_output: false,
        commands: [{ command: :close, reply: false_like_reply }]
      ) do |_ack_port|
        assert_false receive_ractor(false_like_reply)
      end
    ensure
      Julewire::Ractor::PortLifecycle.close(nil_reply) if nil_reply
      Julewire::Ractor::PortLifecycle.close(false_like_reply) if false_like_reply
    end

    def test_worker_contains_unowned_flush_failures_while_closing
      output = WorkerOutput.new(flush_error: RuntimeError.new("flush failed"))

      assert_worker_close(output: output, expected: false, close_output: false)
    end

    def test_worker_skips_lifecycle_for_an_already_closed_output
      output = WorkerOutput.new(closed: true)
      reply = ::Ractor::Port.new

      run_worker(output: output, commands: [{ command: :close, reply: reply }]) do
        assert_true receive_ractor(reply)
      end

      assert_equal %i[closed? closed?], output.calls
    ensure
      Julewire::Ractor::PortLifecycle.close(reply) if reply
    end

    def test_worker_accepts_outputs_without_lifecycle_methods
      flush_reply = ::Ractor::Port.new
      close_reply = ::Ractor::Port.new

      run_worker(
        output: Object.new,
        commands: [{ command: :flush, reply: flush_reply }, { command: :close, reply: close_reply }]
      ) do
        assert_true receive_ractor(flush_reply)
        assert_true receive_ractor(close_reply)
      end
    ensure
      Julewire::Ractor::PortLifecycle.close(flush_reply) if flush_reply
      Julewire::Ractor::PortLifecycle.close(close_reply) if close_reply
    end

    def test_worker_rejects_unknown_commands
      error = assert_raises(ArgumentError) do
        run_worker(output: WorkerOutput.new, commands: [{ command: :unknown }])
      end

      assert_equal "unknown ractor destination command: :unknown", error.message
    end

    def test_worker_rejects_non_port_replies
      error = assert_raises(TypeError) do
        run_worker(output: WorkerOutput.new, commands: [{ command: :flush, reply: InvalidReply.new }])
      end

      assert_equal "ractor destination reply must be a Ractor::Port", error.message
    end

    def test_worker_records_reply_send_failures_but_continues_processing
      closed_reply = ::Ractor::Port.new
      health_reply = ::Ractor::Port.new
      Julewire::Ractor::PortLifecycle.close(closed_reply)

      run_worker(
        output: WorkerOutput.new,
        commands: [{ command: :flush, reply: closed_reply }, { command: :health, reply: health_reply },
                   { command: :close_worker }]
      ) do |_ack_port|
        health = receive_ractor(health_reply)

        assert_equal :degraded, health.fetch(:status)
        assert_equal :reply, health.dig(:last_failure, :phase)
        assert_equal "Ractor::ClosedError", health.dig(:last_failure, :class)
      end
    ensure
      Julewire::Ractor::PortLifecycle.close(health_reply) if health_reply
    end

    def test_worker_closes_owned_output_and_acks_when_command_port_closes
      command_port = ::Ractor::Port.new
      ack_port = ::Ractor::Port.new
      output = WorkerOutput.new
      Julewire::Ractor::PortLifecycle.close(command_port)

      safe_thread_value(
        safe_thread do
          destination_worker_class.run(
            command_port: command_port,
            ack_port: ack_port,
            formatter: ->(record) { record },
            encoder: ->(record) { record },
            output: output,
            max_record_bytes: nil,
            close_output: true
          )
        end,
        timeout: 0.1
      )

      assert_equal %i[closed? close], output.calls
    ensure
      Julewire::Ractor::PortLifecycle.close(command_port) if command_port
      Julewire::Ractor::PortLifecycle.close(ack_port) if ack_port
    end

    def test_worker_contains_owned_output_close_failures
      output = WorkerOutput.new(close_error: RuntimeError.new("close failed"))

      assert_worker_close(output: output, expected: false)

      assert_equal %i[closed? close closed? close], output.calls
    end

    def test_worker_does_not_call_missing_close_through_method_missing
      output = NoCloseOutput.new

      run_worker(output: output, commands: [{ command: :close_worker }])

      assert_empty output.missing_calls
    end

    def test_worker_rejects_non_hash_and_missing_command_messages
      malformed_messages = [Object.new, {}]

      malformed_messages.each do |message|
        assert_raises(TypeError, KeyError) do
          run_worker(output: WorkerOutput.new, commands: [message])
        end
      end
    end

    def test_worker_rejects_emit_commands_without_a_record
      assert_raises(KeyError) do
        run_worker(output: WorkerOutput.new, commands: [{ command: :emit, degradation_marker: nil }])
      end
    end

    private

    def assert_worker_transform_failure(transform:, callable:, counter:, phase:)
      reply = ::Ractor::Port.new
      output = WorkerOutput.new
      options = {
        output: output,
        commands: emit_health_and_close_commands(message: "ignored", reply: reply),
        transform => callable
      }

      run_worker(**options) do |ack_port|
        health = receive_ractor(reply)

        assert_equal [{ degradation_marker: nil, event: :ack, status: :dropped }], receive_messages(ack_port, 1)
        assert_equal 1, health.dig(:counts, counter)
        assert_equal phase, health.dig(:last_failure, :phase)
        assert_equal "RuntimeError", health.dig(:last_failure, :class)
        refute_includes health.fetch(:last_failure), :record
        assert_nil health[:last_loss]
      end

      assert_empty output.written
    ensure
      Julewire::Ractor::PortLifecycle.close(reply) if reply
    end

    def assert_worker_close(output:, expected:, close_output: true)
      reply = ::Ractor::Port.new

      run_worker(
        output: output,
        close_output: close_output,
        commands: [{ command: :close, reply: reply }]
      ) do
        assert_equal expected, receive_ractor(reply)
      end
    ensure
      Julewire::Ractor::PortLifecycle.close(reply) if reply
    end

    def emit_health_and_close_commands(message:, reply:)
      [
        { command: :emit, degradation_marker: nil, record: { message: message } },
        { command: :health, reply: reply },
        { command: :close_worker }
      ]
    end

    def run_worker(
      output:,
      commands:,
      close_output: true,
      formatter: ->(record) { record },
      encoder: ->(record) { record },
      max_record_bytes: nil
    )
      command_port = ::Ractor::Port.new
      ack_port = ::Ractor::Port.new
      thread = safe_thread do
        destination_worker_class.run(
          command_port: command_port,
          ack_port: ack_port,
          formatter: formatter,
          encoder: encoder,
          output: output,
          max_record_bytes: max_record_bytes,
          close_output: close_output
        )
      end
      commands.each { command_port.send(it) }

      yield ack_port if block_given?

      safe_thread_value(thread, timeout: 0.1)
    ensure
      Julewire::Ractor::PortLifecycle.close(command_port) if command_port
      Julewire::Ractor::PortLifecycle.close(ack_port) if ack_port
    end

    def receive_messages(port, count)
      Array.new(count) { receive_ractor(port) }
    end

    def destination_worker_class
      Julewire::Ractor.const_get(:DestinationWorker, false)
    end

    class WorkerOutput
      attr_reader :calls, :written

      def initialize(closed: false, write_result: true, flush_result: true, close_result: true, write_error: nil,
                     flush_error: nil, close_error: nil)
        @closed = closed
        @write_result = write_result
        @flush_result = flush_result
        @close_result = close_result
        @write_error = write_error
        @flush_error = flush_error
        @close_error = close_error
        @calls = []
        @written = []
      end

      def write(value)
        @calls << :write
        raise @write_error if @write_error

        @written << value
        @write_result
      end

      def closed?
        @calls << :closed?
        @closed
      end

      def flush
        @calls << :flush
        raise @flush_error if @flush_error

        @flush_result
      end

      def close
        @calls << :close
        raise @close_error if @close_error

        @closed = true unless @close_result == false
        @close_result
      end
    end

    class RecoveringWorkerOutput
      attr_reader :written

      def initialize
        @write_failed = false
        @flush_failed = false
        @written = []
      end

      def write(value) # rubocop:disable Naming/PredicateMethod -- Output protocol uses truthy write results.
        unless @write_failed
          @write_failed = true
          raise "write failed"
        end

        @written << value
        true
      end

      def flush # rubocop:disable Naming/PredicateMethod -- Output protocol uses truthy flush results.
        unless @flush_failed
          @flush_failed = true
          raise "flush failed"
        end

        true
      end

      def closed? = false
      def close = true # rubocop:disable Naming/PredicateMethod -- Output protocol uses truthy close results.
    end

    class FalseLike
      def ==(other) = other == false
    end

    class InvalidReply
      def send(_message)
        raise "invalid reply used"
      end
    end

    class NoCloseOutput
      attr_reader :missing_calls

      def initialize
        @missing_calls = []
      end

      def method_missing(name, *_arguments)
        @missing_calls << name
      end

      def respond_to_missing?(_name, _include_private) = false
    end
  end
end
