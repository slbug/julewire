# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestRactorBridgeStats < Minitest::Test
    cover Julewire::Ractor::Bridge::Stats

    def setup
      super
      stats.after_fork!
    end

    def test_bridge_started_and_stopped_track_thread_counts
      stats.bridge_started
      stats.bridge_started
      stats.bridge_stopped

      health = stats.health

      assert health.fetch(:experimental)
      assert_equal 1, health.fetch(:active_threads)
      assert_equal 2, health.fetch(:started_threads)
      assert_equal 1, health.fetch(:stopped_threads)
      assert_equal 0, health.fetch(:failure_count)
      refute health.key?(:last_error_class)
    end

    def test_bridge_stopped_does_not_make_active_thread_count_negative
      stats.bridge_stopped

      health = stats.health

      assert_equal 0, health.fetch(:active_threads)
      assert_equal 1, health.fetch(:stopped_threads)
    end

    def test_bridge_stopped_records_errors
      stats.bridge_started
      stats.bridge_stopped(RuntimeError.new("boom"))

      health = stats.health

      assert_equal 0, health.fetch(:active_threads)
      assert_equal 1, health.fetch(:failure_count)
      assert_equal "RuntimeError", health.fetch(:last_error_class)
    end

    def test_message_and_failure_counters
      stats.message_received
      stats.message_received
      stats.message_failed(ArgumentError.new("bad"))

      health = stats.health

      assert_equal 2, health.fetch(:messages)
      assert_equal 1, health.fetch(:failure_count)
      assert_equal "ArgumentError", health.fetch(:last_error_class)
    end

    def test_reset_clears_history_but_preserves_active_thread_count
      stats.bridge_started
      stats.message_received
      stats.bridge_stopped(RuntimeError.new("boom"))
      stats.bridge_started

      stats.reset!
      health = stats.health

      assert_equal 1, health.fetch(:active_threads)
      assert_equal 0, health.fetch(:messages)
      assert_equal 0, health.fetch(:failure_count)
      assert_equal 0, health.fetch(:started_threads)
      assert_equal 0, health.fetch(:stopped_threads)
      refute health.key?(:last_error_class)
    end

    def test_after_fork_clears_active_threads_and_history
      stats.bridge_started
      stats.message_received
      stats.message_failed(RuntimeError.new("boom"))

      assert_nil stats.after_fork!

      health = stats.health

      assert_equal 0, health.fetch(:active_threads)
      assert_equal 0, health.fetch(:messages)
      assert_equal 0, health.fetch(:failure_count)
      assert_equal 0, health.fetch(:started_threads)
      assert_equal 0, health.fetch(:stopped_threads)
      refute health.key?(:last_error_class)
    end

    private

    def stats = Julewire::Ractor::Bridge::Stats
  end
end
