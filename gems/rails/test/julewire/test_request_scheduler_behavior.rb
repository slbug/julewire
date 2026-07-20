# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestRequestSummaryTimeoutScheduler < Minitest::Test
    cover Julewire::Rails::RequestSummaryTimeoutScheduler

    def test_request_summary_timeout_scheduler_ignores_nil_timeout
      called = false

      assert_nil Julewire::Rails::RequestSummaryTimeoutScheduler.schedule(nil) { called = true }
      assert_false called
    end

    def test_request_summary_timeout_scheduler_runs_non_positive_timeout_inline
      ran_inline = false

      assert_nil Julewire::Rails::RequestSummaryTimeoutScheduler.schedule(0) { ran_inline = true }
      assert_true ran_inline
    end

    def test_request_summary_timeout_scheduler_cancel_suppresses_callback
      queue = Queue.new

      token = Julewire::Rails::RequestSummaryTimeoutScheduler.schedule(0.01) { queue << :cancelled }

      Julewire::Rails::RequestSummaryTimeoutScheduler.cancel(token)
      Julewire::Rails::RequestSummaryTimeoutScheduler.schedule(0.02) { queue << :sentinel }

      assert_equal :sentinel, Timeout.timeout(1) { queue.pop }
      assert_predicate queue, :empty?
    end

    def test_request_summary_timeout_scheduler_after_fork_resets_pending_callbacks
      queue = Queue.new

      Julewire::Rails::RequestSummaryTimeoutScheduler.schedule(1) { queue << :old }
      Julewire::Rails::RequestSummaryTimeoutScheduler.after_fork!
      Julewire::Rails::RequestSummaryTimeoutScheduler.schedule(0.001) { queue << :new }

      assert_equal :new, Timeout.timeout(1) { queue.pop }
      assert_predicate queue, :empty?
    end

    def test_request_summary_timeout_scheduler_delegates_to_shared_scheduler
      calls = []
      fake_scheduler = Module.new do
        define_singleton_method(:schedule) do |timeout, &block|
          calls << [:schedule, timeout, block.call]
          :token
        end

        define_singleton_method(:cancel) do |token|
          calls << [:cancel, token]
        end

        define_singleton_method(:after_fork!) do
          calls << [:after_fork]
        end
      end

      with_temporary_constant(Julewire::Core::Scheduling, :SharedScheduler, fake_scheduler) do
        assert_equal :token, Julewire::Rails::RequestSummaryTimeoutScheduler.schedule(0.25) { :ran }
        Julewire::Rails::RequestSummaryTimeoutScheduler.cancel(:token)
        Julewire::Rails::RequestSummaryTimeoutScheduler.after_fork!
      end

      assert_equal [[:schedule, 0.25, :ran], %i[cancel token], [:after_fork]], calls
    end

    def test_request_summary_timeout_scheduler_does_not_delegate_missing_inputs
      calls = []
      fake_scheduler = Module.new do
        define_singleton_method(:schedule) do |*|
          calls << :schedule
          :scheduled
        end

        define_singleton_method(:cancel) do |*|
          calls << :cancel
          :cancelled
        end
      end

      with_temporary_constant(Julewire::Core::Scheduling, :SharedScheduler, fake_scheduler) do
        assert_nil Julewire::Rails::RequestSummaryTimeoutScheduler.schedule(nil) { :ignored }
        assert_nil Julewire::Rails::RequestSummaryTimeoutScheduler.schedule(0.25)
        assert_nil Julewire::Rails::RequestSummaryTimeoutScheduler.cancel(nil)
      end

      assert_empty calls
    end

    def test_request_summary_timeout_scheduler_contains_shared_scheduler_failures
      fake_scheduler = Module.new do
        def self.schedule(*) = raise "schedule failed"
        def self.cancel(*) = raise "cancel failed"
      end

      with_temporary_constant(Julewire::Core::Scheduling, :SharedScheduler, fake_scheduler) do
        assert_nil Julewire::Rails::RequestSummaryTimeoutScheduler.schedule(0.25) { :ignored }
        assert_nil Julewire::Rails::RequestSummaryTimeoutScheduler.cancel(:token)
      end
    end
  end
end
