# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestBacktraceLimiter < Minitest::Test
    cover Julewire::Core::Serialization::BacktraceLimiter
    class AlwaysEqualHash < Hash
      def eql?(_other) = true

      def hash = 0
    end

    class CountingBacktraceHash < Hash
      attr_reader :backtrace_key_checks

      def initialize(...)
        super
        @backtrace_key_checks = 0
      end

      def key?(key)
        @backtrace_key_checks = backtrace_key_checks.to_i + 1 if key == :backtrace
        super
      end
    end

    def test_requires_named_non_negative_limit
      error = assert_raises(ArgumentError) do
        Julewire::Core::Serialization::BacktraceLimiter.new(max_backtrace_lines: "bad")
      end

      assert_equal "max_backtrace_lines must be a non-negative Integer", error.message
    end

    def test_handles_cyclic_cause_hash
      error = { backtrace: ["root.rb:1", "root.rb:2"] }
      error[:cause] = error

      limited = Julewire::Core::Serialization::BacktraceLimiter.call(error, max_backtrace_lines: 1)

      assert_equal ["root.rb:1"], limited.fetch(:backtrace)
      assert_same error, limited.fetch(:cause)
    end

    def test_visits_cyclic_cause_hash_once
      error = CountingBacktraceHash[backtrace: ["root.rb:1", "root.rb:2"]]
      error[:cause] = error

      Julewire::Core::Serialization::BacktraceLimiter.call(error, max_backtrace_lines: 1)

      assert_equal 1, error.backtrace_key_checks
    end

    def test_tracks_seen_hashes_by_identity
      first = AlwaysEqualHash[backtrace: ["first.rb:1", "first.rb:2"]]
      second = AlwaysEqualHash[backtrace: ["second.rb:1", "second.rb:2"]]
      first[:cause] = second

      Julewire::Core::Serialization::BacktraceLimiter.call(first, max_backtrace_lines: 1)

      assert_equal ["first.rb:1"], first.fetch(:backtrace)
      assert_equal ["second.rb:1"], second.fetch(:backtrace)
    end

    def test_reuses_limiter_across_calls
      limiter = Julewire::Core::Serialization::BacktraceLimiter.new(max_backtrace_lines: 1)
      error = { backtrace: ["first.rb:1", "first.rb:2"] }

      limiter.call(error)
      error[:backtrace] = ["second.rb:1", "second.rb:2"]
      limiter.call(error)

      assert_equal ["second.rb:1"], error.fetch(:backtrace)
    end

    def test_ignores_non_hash_causes
      error = {
        backtrace: %w[first second],
        cause: "string-cause"
      }

      limited = Julewire::Core::Serialization::BacktraceLimiter.call(error, max_backtrace_lines: 1)

      assert_equal ["first"], limited.fetch(:backtrace)
      assert_equal "string-cause", limited.fetch(:cause)
    end

    def test_accepts_hash_subclass_causes
      cause = Class.new(Hash).new
      cause[:backtrace] = %w[cause-first cause-second]
      error = {
        backtrace: %w[first second],
        cause: cause
      }

      limited = Julewire::Core::Serialization::BacktraceLimiter.call(error, max_backtrace_lines: 1)

      assert_equal ["first"], limited.fetch(:backtrace)
      assert_equal ["cause-first"], limited.fetch(:cause).fetch(:backtrace)
    end

    def test_trims_deep_core_shaped_cause_hashes
      error = { backtrace: ["root.rb:1"] }
      current = error
      7.times do |index|
        current[:cause] = { backtrace: ["cause-#{index}.rb:1"] }
        current = current.fetch(:cause)
      end

      limited = Julewire::Core::Serialization::BacktraceLimiter.call(error, max_backtrace_lines: 0)

      while limited
        refute_includes limited, :backtrace
        limited = limited[:cause]
      end
    end

    def test_bounds_cause_hash_traversal_depth
      error = { backtrace: ["root.rb:1", "root.rb:2"] }
      current = error
      Julewire::Core::NORMALIZATION_MAX_DEPTH.times do |index|
        current[:cause] = { backtrace: ["cause-#{index}.rb:1", "cause-#{index}.rb:2"] }
        current = current.fetch(:cause)
      end

      Julewire::Core::Serialization::BacktraceLimiter.call(error, max_backtrace_lines: 0)

      current = error
      Julewire::Core::NORMALIZATION_MAX_DEPTH.times do
        refute_includes current, :backtrace
        current = current.fetch(:cause)
      end
      index = Julewire::Core::NORMALIZATION_MAX_DEPTH - 1

      assert_equal ["cause-#{index}.rb:1", "cause-#{index}.rb:2"], current.fetch(:backtrace)
    end

    def test_ignores_missing_backtrace_without_triggering_hash_default
      default_keys = []
      error = Hash.new do |_hash, key|
        default_keys << key
        ["generated"] if key == :backtrace
      end

      limited = Julewire::Core::Serialization::BacktraceLimiter.call(error, max_backtrace_lines: 1)

      assert_same error, limited
      refute_includes default_keys, :backtrace
      refute_includes error, :backtrace
    end

    def test_leaves_non_array_backtrace_values_unchanged
      error = { backtrace: "app.rb:1" }

      limited = Julewire::Core::Serialization::BacktraceLimiter.call(error, max_backtrace_lines: 1)

      assert_equal "app.rb:1", limited.fetch(:backtrace)
    end

    def test_limits_array_subclass_backtraces
      backtrace = Class.new(Array).new(["app.rb:1", "app.rb:2"])
      error = { backtrace: backtrace }

      limited = Julewire::Core::Serialization::BacktraceLimiter.call(error, max_backtrace_lines: 1)

      assert_equal ["app.rb:1"], limited.fetch(:backtrace)
    end
  end
end
