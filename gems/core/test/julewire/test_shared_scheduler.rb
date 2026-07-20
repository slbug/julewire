# frozen_string_literal: true

require "test_helper"
require "timeout"

module Julewire
  class TestSharedScheduler < Minitest::Test
    cover Julewire::Core::Scheduling::SharedScheduler

    ASYNC_TIMEOUT = 0.5

    def teardown
      Core::Scheduling::SharedScheduler.after_fork!
    end

    def test_non_positive_timeouts_run_inline_and_strings_are_coerced
      [0, -1, "0"].each do |timeout|
        called = false

        result = scheduler.schedule(timeout) { called = true }

        assert_true called
        assert_nil result
      end
    end

    def test_schedule_requires_a_block
      error = assert_raises(ArgumentError) { scheduler.schedule(1) }

      assert_equal "block required", error.message
    end

    def test_callbacks_run_by_deadline_and_errors_do_not_stop_later_work
      queue = Queue.new

      scheduler.schedule(0.03) { queue << :later }
      scheduler.schedule(0.005) { raise "boom" }
      scheduler.schedule(0.01) { queue << :earlier }

      assert_equal :earlier, pop(queue)
      assert_equal :later, pop(queue)
    end

    def test_cancel_accepts_nil_and_suppresses_pending_work
      queue = Queue.new
      cancelled = scheduler.schedule(0.03) { queue << :cancelled }

      assert_nil scheduler.cancel(nil)
      assert_nil scheduler.cancel(cancelled)
      scheduler.schedule(0.06) { queue << :sentinel }

      assert_equal :sentinel, pop(queue)
      assert_predicate queue, :empty?
    end

    def test_callbacks_are_serialized_on_the_named_worker
      entered = Queue.new
      release = Queue.new
      scheduler.schedule(0.01) do
        entered << [:first, Thread.current.name]
        release.pop
      end
      scheduler.schedule(0.02) { entered << [:second, Thread.current.name] }

      assert_equal [:first, Core::Scheduling::SharedScheduler::THREAD_NAME], pop(entered)
      sleep 0.03

      assert_predicate entered, :empty?

      release << true

      assert_equal [:second, Core::Scheduling::SharedScheduler::THREAD_NAME], pop(entered)
    ensure
      release&.push(true)
    end

    def test_after_fork_resets_pending_work
      queue = Queue.new
      scheduler.schedule(0.05) { queue << :old }

      assert_nil scheduler.after_fork!

      scheduler.schedule(0.01) { queue << :new }
      scheduler.schedule(0.1) { queue << :sentinel }

      assert_equal :new, pop(queue)
      assert_equal :sentinel, pop(queue)
      assert_predicate queue, :empty?
    end

    # The ensure block owns real child-process and pipe cleanup after the platform guard.
    # rubocop:disable Minitest/SkipEnsure
    def test_after_fork_discards_inherited_work_in_a_real_child
      skip "Process.fork is unavailable" unless Process.respond_to?(:fork)

      reader, writer = IO.pipe
      scheduler.schedule(0.05) { writer.write("old") }
      child_pid = Process.fork do
        reader.close
        scheduler.after_fork!
        scheduler.schedule(0.01) { writer.write("new") }
        sleep 0.1
        scheduler.after_fork!
        writer.close
        exit! 0
      end
      writer.close

      output = Timeout.timeout(1) { reader.read }
      _, status = Process.wait2(child_pid)
      child_pid = nil

      assert_predicate status, :success?
      assert_equal "new", output
    ensure
      reader&.close unless reader&.closed?
      writer&.close unless writer&.closed?
      if child_pid
        Process.kill("KILL", child_pid)
        Process.wait(child_pid)
      end
    end
    # rubocop:enable Minitest/SkipEnsure

    private

    def scheduler = Core::Scheduling::SharedScheduler

    def pop(queue)
      Timeout.timeout(ASYNC_TIMEOUT) { queue.pop }
    end
  end
end
