# frozen_string_literal: true

require "test_helper"
require "timeout"

module Julewire
  class TestReplyTimeoutScheduler < Minitest::Test
    cover "Julewire::Ractor::ReplyTimeoutScheduler#cancel"
    cover "Julewire::Ractor::ReplyTimeoutScheduler#initialize"
    cover "Julewire::Ractor::ReplyTimeoutScheduler#schedule"
    cover "Julewire::Ractor::ReplyTimeoutScheduler#send_timeout"
    cover "Julewire::Ractor::ReplyTimeoutScheduler#with_timeout"

    class ReplyProbe
      attr_reader :messages

      def initialize
        @messages = []
      end

      def send(message)
        @messages << message
      end
    end

    class FailingReply
      def send(_message)
        raise "reply failed"
      end
    end

    def test_schedule_sends_zero_timeouts
      reply = ReplyProbe.new
      thread = scheduler.schedule(reply, timeout: 0)

      safe_thread_value(thread)

      assert_equal [:timeout], reply.messages
    end

    def test_schedule_rejects_missing_timeout_before_starting_a_thread
      reply = ReplyProbe.new

      assert_raises(TypeError) { scheduler.schedule(reply, timeout: nil) }

      assert_empty reply.messages
    end

    def test_positive_timeout_waits_before_sending
      reply = ReplyProbe.new
      thread = scheduler.schedule(reply, timeout: 1)

      Timeout.timeout(1) { Thread.pass until thread.status == "sleep" }

      assert_empty reply.messages
      assert_nil scheduler.cancel(thread)
      refute_predicate thread, :alive?
    end

    def test_schedule_delegates_positive_timeouts
      reply = ::Ractor::Port.new

      token = scheduler.schedule(reply, timeout: 0.01)

      refute_nil token
      assert_equal :timeout, receive_ractor(reply)
      refute_predicate token, :alive?
    ensure
      Julewire::Ractor::PortLifecycle.close(reply) if reply
    end

    def test_with_timeout_cancels_a_pending_timeout_when_the_operation_raises
      reply = ::Ractor::Port.new

      error = assert_raises(RuntimeError) do
        scheduler.with_timeout(reply, timeout: 0.05) { raise "operation failed" }
      end

      assert_equal "operation failed", error.message
      assert_raises(Timeout::Error) { Timeout.timeout(0.08) { reply.receive } }
    ensure
      Julewire::Ractor::PortLifecycle.close(reply) if reply
    end

    def test_with_timeout_unblocks_the_operation_when_the_timeout_expires
      reply = ::Ractor::Port.new

      result = scheduler.with_timeout(reply, timeout: 0) { receive_ractor(reply) }

      assert_equal :timeout, result
    ensure
      Julewire::Ractor::PortLifecycle.close(reply) if reply
    end

    def test_scheduled_callbacks_use_the_reply_timeout_thread_name
      entered = Queue.new
      release = Queue.new
      reply = Object.new
      reply.define_singleton_method(:send) do |_message|
        entered << Thread.current.name
        release.pop
      end

      thread = scheduler.schedule(reply, timeout: 0.01)

      assert_equal Julewire::Ractor::ReplyTimeoutScheduler::THREAD_NAME, safe_queue_pop(entered, timeout: 0.1)
    ensure
      release&.push(true)
      thread&.join(1)
    end

    def test_cancel_accepts_nil_and_prevents_a_pending_timeout
      reply = ::Ractor::Port.new
      token = scheduler.schedule(reply, timeout: 0.05)

      assert_nil scheduler.cancel(nil)
      assert_nil scheduler.cancel(token)
      refute_predicate token, :alive?
      assert_raises(Timeout::Error) { Timeout.timeout(0.08) { reply.receive } }
    ensure
      Julewire::Ractor::PortLifecycle.close(reply) if reply
    end

    def test_schedule_swallows_reply_failures
      thread = scheduler.schedule(FailingReply.new, timeout: 0)

      assert_nil safe_thread_value(thread)
      refute_predicate thread, :alive?
    end

    private

    def scheduler
      @scheduler ||= Julewire::Ractor::ReplyTimeoutScheduler.new(timeout_value: :timeout)
    end
  end
end
