# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestRactorChildStatsObject < Minitest::Test
    cover "Julewire::Ractor::ChildStats*"
    def setup
      super
      @stats = child_stats_class.new
    end

    def test_initial_stats_shape
      snapshot = @stats.to_h

      assert_predicate snapshot, :frozen?
      assert_predicate snapshot.fetch(:counts), :frozen?
      assert_equal(
        {
          messages_dropped: 0,
          messages_sent: 0,
          requests_failed: 0,
          requests_sent: 0,
          requests_timed_out: 0
        },
        snapshot.fetch(:counts)
      )
      assert_false snapshot.key?(:last_error_class)
    end

    def test_message_and_request_counters
      assert_nil @stats.message_sent
      assert_nil @stats.request_sent
      assert_nil @stats.request_timed_out

      counts = @stats.to_h.fetch(:counts)

      assert_equal 1, counts.fetch(:messages_sent)
      assert_equal 1, counts.fetch(:requests_sent)
      assert_equal 1, counts.fetch(:requests_timed_out)
      assert_equal 0, counts.fetch(:messages_dropped)
      assert_equal 0, counts.fetch(:requests_failed)
    end

    def test_error_counters_record_last_error_class
      assert_nil @stats.message_dropped(RuntimeError.new("drop"))

      message_snapshot = @stats.to_h

      assert_equal 1, message_snapshot.dig(:counts, :messages_dropped)
      assert_equal "RuntimeError", message_snapshot.fetch(:last_error_class)

      assert_nil @stats.request_failed(ArgumentError.new("fail"))

      snapshot = @stats.to_h
      counts = snapshot.fetch(:counts)

      assert_equal 1, counts.fetch(:messages_dropped)
      assert_equal 1, counts.fetch(:requests_failed)
      assert_equal "ArgumentError", snapshot.fetch(:last_error_class)
    end

    def test_reset_clears_counters_and_last_error
      @stats.message_sent
      @stats.message_dropped(RuntimeError.new("drop"))

      assert_nil @stats.reset!

      snapshot = @stats.to_h

      assert_equal(
        {
          messages_dropped: 0,
          messages_sent: 0,
          requests_failed: 0,
          requests_sent: 0,
          requests_timed_out: 0
        },
        snapshot.fetch(:counts)
      )
      assert_false snapshot.key?(:last_error_class)
    end

    def test_counters_are_thread_safe
      threads = Array.new(8) do
        safe_thread do
          250.times { @stats.message_sent }
          nil
        rescue StandardError => e
          e
        end
      end

      errors = safe_thread_values(threads).grep(StandardError)

      assert_empty errors
      assert_equal 2_000, @stats.to_h.dig(:counts, :messages_sent)
    end

    private

    def child_stats_class = Julewire::Ractor.const_get(:ChildStats, false)
  end
end
