# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestBacktraceLimiter < Minitest::Test
    cover Julewire::Core::Serialization::BacktraceLimiter

    def test_handles_cyclic_cause_hash
      error = { backtrace: ["root.rb:1", "root.rb:2"] }
      error[:cause] = error

      limited = Julewire::Core::Serialization::BacktraceLimiter.call(error, max_backtrace_lines: 1)

      assert_equal ["root.rb:1"], limited.fetch(:backtrace)
      assert_same error, limited.fetch(:cause)
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
  end
end
