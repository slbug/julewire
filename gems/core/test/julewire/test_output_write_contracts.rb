# frozen_string_literal: true

require "test_helper"
require "stringio"

module Julewire
  class TestOutputWriteContracts < Minitest::Test
    class PlainFalseOutput
      def initialize
        @result = false
      end

      def write(_value)
        @result
      end
    end

    class FlakyFalseOutput
      def initialize
        @failed = false
      end

      def write(_value) # rubocop:disable Naming/PredicateMethod -- Output protocol method.
        return true if @failed

        @failed = true
        false
      end
    end

    def test_plain_false_output_results_are_counted_as_rejections
      assert_single_output_write_health(
        PlainFalseOutput.new,
        output_accepted: 0,
        rejected: 1,
        output_error: 1,
        output_rejection_drops: 1
      )
    end

    def test_plain_false_output_is_not_counted_as_accepted_when_on_drop_fails
      Julewire.configure do |config|
        configure_destination(config, output: PlainFalseOutput.new)
        config.on_drop = ->(_reason, _metadata) { raise "drop callback failed" }
      end

      Julewire.emit(message: "output")

      health = Julewire.health
      counts = health.dig(:pipeline, :destinations, :default, :counts)

      assert_equal 0, counts.fetch(:output_accepted)
      assert_equal 1, counts.fetch(:output_rejected)
      assert_equal 1, counts.fetch(:output_error)
      assert_equal 1, counts.fetch(:callback_error)
      assert_equal :output_rejected, health.dig(:pipeline, :destinations, :default, :last_loss, :reason)
    end

    def test_rejection_history_remains_after_degraded_status_recovers
      Julewire.configure { configure_destination(it, output: FlakyFalseOutput.new) }

      Julewire.emit(message: "reject")

      assert_equal :degraded, Julewire.health.dig(:pipeline, :destinations, :default, :status)

      Julewire.emit(message: "recover")
      health = Julewire.health.dig(:pipeline, :destinations, :default)

      assert_equal :ok, health.fetch(:status)
      assert_equal :output_rejected, health.dig(:last_loss, :reason)
      assert_equal 1, health.dig(:counts, :output_rejected)
      assert_equal 1, health.dig(:counts, :output_accepted)
    end

    def test_non_false_output_results_are_counted_as_accepted
      Julewire.configure { configure_destination(it, output: StringIO.new) }

      Julewire.emit(message: "output")

      health = Julewire.health

      counts = health.dig(:pipeline, :destinations, :default, :counts)

      assert_equal 1, counts.fetch(:output_accepted)
      assert_equal 0, counts.fetch(:output_rejected)
      assert_equal 0, counts.fetch(:output_error)
      assert_equal 0, counts.fetch(:output_exception)
    end

    private

    def assert_single_output_write_health(output, output_accepted:, rejected:, output_error:, output_rejection_drops:)
      drops = configure_output_with_drop_capture(output)

      Julewire.emit(message: "output")

      health = Julewire.health

      assert_equal output_rejection_drops, nonblocking_queue_values(drops).length
      assert_equal output_accepted, health.dig(:pipeline, :destinations, :default, :counts, :output_accepted)
      assert_equal rejected, health.dig(:pipeline, :destinations, :default, :counts, :output_rejected)
      assert_equal output_error, health.dig(:pipeline, :destinations, :default, :counts, :output_error)
      assert_equal :output_rejected, health.dig(:pipeline, :destinations, :default, :last_loss, :reason)
    end
  end
end
