# frozen_string_literal: true

require "test_helper"
require "timeout"

module Julewire
  class TestDeadlineScheduler < Minitest::Test
    def test_schedule_runs_zero_timeout_inline
      scheduler = Core::Scheduling::DeadlineScheduler.new(thread_name: "julewire-test-deadline")
      called = false

      result = scheduler.schedule(0) { called = true }

      assert called
      assert_nil result
    end

    def test_schedule_requires_block
      scheduler = Core::Scheduling::DeadlineScheduler.new(thread_name: "julewire-test-deadline")

      error = assert_raises(ArgumentError) { scheduler.schedule(1) }

      assert_equal "block required", error.message
    end

    def test_schedule_runs_expired_callback
      scheduler = Core::Scheduling::DeadlineScheduler.new(thread_name: "julewire-test-deadline", idle: :exit)
      queue = Queue.new

      scheduler.schedule(0.001) { queue << :done }

      assert_equal :done, Timeout.timeout(1) { queue.pop }
    end

    def test_cancel_suppresses_callback
      assert_cancelled_callback_skipped(cancel_timeout: 0.01, next_timeout: 0.02, next_value: :sentinel)
    end

    def test_cancel_nil_is_noop
      scheduler = Core::Scheduling::DeadlineScheduler.new(thread_name: "julewire-test-deadline")

      assert_nil scheduler.cancel(nil)
    end

    def test_cancelled_head_does_not_block_later_callback
      assert_cancelled_callback_skipped(cancel_timeout: 0.5, next_timeout: 0.001, next_value: :done)
    end

    def test_callbacks_run_by_deadline_not_schedule_order
      scheduler = Core::Scheduling::DeadlineScheduler.new(thread_name: "julewire-test-deadline", idle: :exit)
      queue = Queue.new

      scheduler.schedule(0.03) { queue << :later }
      scheduler.schedule(0.001) { queue << :earlier }

      assert_equal :earlier, Timeout.timeout(1) { queue.pop }
      assert_equal :later, Timeout.timeout(1) { queue.pop }
    end

    def test_callback_errors_are_swallowed_and_scheduler_continues
      scheduler = Core::Scheduling::DeadlineScheduler.new(thread_name: "julewire-test-deadline", idle: :exit)
      queue = Queue.new

      scheduler.schedule(0.001) { raise "boom" }
      scheduler.schedule(0.002) { queue << :done }

      assert_equal :done, Timeout.timeout(1) { queue.pop }
    end

    def test_keep_alive_scheduler_accepts_work_after_idle
      scheduler = Core::Scheduling::DeadlineScheduler.new(thread_name: "julewire-test-deadline")
      queue = Queue.new

      scheduler.schedule(0.001) { queue << :first }

      assert_equal :first, Timeout.timeout(1) { queue.pop }

      scheduler.schedule(0.001) { queue << :second }

      assert_equal :second, Timeout.timeout(1) { queue.pop }

      scheduler.after_fork!
    end

    def test_after_fork_resets_state
      scheduler = Core::Scheduling::DeadlineScheduler.new(thread_name: "julewire-test-deadline")
      queue = Queue.new

      scheduler.schedule(0.5) { queue << :old }
      scheduler.after_fork!
      scheduler.schedule(0.001) { queue << :new }

      assert_only_callback(queue, :new)
    end

    def test_shared_scheduler_resets_pending_callbacks
      queue = Queue.new

      Core::Scheduling::SharedScheduler.schedule(0.5) { queue << :old }
      Core::Scheduling::SharedScheduler.after_fork!
      Core::Scheduling::SharedScheduler.schedule(0.001) { queue << :new }

      assert_only_callback(queue, :new)
    ensure
      Julewire::Testing.reset_shared_scheduler
    end

    private

    def assert_cancelled_callback_skipped(cancel_timeout:, next_timeout:, next_value:)
      scheduler = Core::Scheduling::DeadlineScheduler.new(thread_name: "julewire-test-deadline", idle: :exit)
      queue = Queue.new
      token = scheduler.schedule(cancel_timeout) { queue << :cancelled }

      scheduler.cancel(token)
      scheduler.schedule(next_timeout) { queue << next_value }

      assert_only_callback(queue, next_value)
    end

    def assert_only_callback(queue, value)
      assert_equal value, Timeout.timeout(1) { queue.pop }
      assert_empty nonblocking_queue_values(queue)
    end
  end
end
