# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestRemoteRuntimeNotify < Minitest::Test
    cover "Julewire::Ractor::RemoteRuntime#notify"
    cover "Julewire::Ractor::RemoteRuntime#request"
    cover "Julewire::Ractor::RemoteRuntime#serialize_remote"

    class RecordingPort
      attr_reader :messages

      def initialize
        @messages = []
      end

      def send(message)
        @messages << message
      end
    end

    class BlockingPort
      attr_reader :entered

      def initialize
        @entered = Queue.new
        @release = Queue.new
      end

      def send(message)
        @entered << message
        @release.pop
        message[:reply]&.send(:ok)
      end

      def release = @release << true
    end

    def test_successful_emit_sends_symbol_protocol_and_updates_child_stats
      port = RecordingPort.new
      runtime = Julewire::Ractor::RemoteRuntime.new(port: port)

      assert_nil runtime.emit(message: "done")

      message = port.messages.fetch(0)

      assert_equal :emit, message.fetch(:command)
      assert_equal({ message: "done" }, message.dig(:payload, :input))
      assert_equal 1, runtime.child_stats.dig(:counts, :messages_sent)
      assert_equal 0, runtime.child_stats.dig(:counts, :messages_dropped)
    end

    def test_truncated_emit_keeps_every_protocol_key_as_a_symbol
      port = RecordingPort.new
      runtime = Julewire::Ractor::RemoteRuntime.new(port: port)
      runtime.context.add(blob: "x" * 20_000)

      runtime.emit(message: "done")

      message = port.messages.fetch(0)

      assert_recursive_symbol_keys(message)
      assert_true message.dig(:payload, :context, :_julewire_truncation, :truncated)
      assert_equal ["blob"], message.dig(:payload, :context, :_julewire_truncation, :truncated_fields)
    end

    def test_concurrent_notifications_are_serialized_at_the_port_boundary
      port = BlockingPort.new
      runtime = Julewire::Ractor::RemoteRuntime.new(port: port)
      first = safe_thread { runtime.emit(message: "first") }
      first_message = safe_queue_pop(port.entered)
      started = Queue.new
      second = safe_thread do
        started << true
        runtime.emit(message: "second")
      end
      safe_queue_pop(started)
      Timeout.timeout(1) { Thread.pass until second.status == "sleep" }

      assert_raises(ThreadError) { port.entered.pop(true) }

      port.release
      second_message = safe_queue_pop(port.entered)
      port.release
      safe_thread_values([first, second])

      assert_equal "first", first_message.dig(:payload, :input, :message)
      assert_equal "second", second_message.dig(:payload, :input, :message)
    ensure
      2.times { port&.release }
      [first, second].compact.each { cleanup_thread(it) }
    end

    def test_concurrent_requests_are_serialized_at_the_port_boundary
      port = BlockingPort.new
      runtime = Julewire::Ractor::RemoteRuntime.new(port: port)
      first = safe_thread { runtime.flush(timeout: nil) }
      first_message = safe_queue_pop(port.entered)
      started = Queue.new
      second = safe_thread do
        started << true
        runtime.flush(timeout: nil)
      end
      safe_queue_pop(started)
      Timeout.timeout(1) { Thread.pass until second.status == "sleep" }

      assert_raises(ThreadError) { port.entered.pop(true) }

      port.release
      second_message = safe_queue_pop(port.entered)
      port.release

      assert_equal %i[ok ok], safe_thread_values([first, second])
      assert_equal :flush, first_message.fetch(:command)
      assert_equal :flush, second_message.fetch(:command)
    ensure
      2.times { port&.release }
      [first, second].compact.each { cleanup_thread(it) }
    end

    private

    def assert_recursive_symbol_keys(value)
      case value
      when Hash
        value.each do |key, child|
          assert_instance_of Symbol, key
          assert_recursive_symbol_keys(child)
        end
      when Array
        value.each { assert_recursive_symbol_keys(it) }
      end
    end
  end
end
