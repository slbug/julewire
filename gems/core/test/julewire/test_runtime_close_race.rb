# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestRuntimeCloseRace < Minitest::Test
    class BlockingCloseOutput
      attr_reader :closed_count

      def initialize(ready:, release:)
        @ready = ready
        @release = release
        @closed_count = 0
      end

      def write(_value); end

      def close
        @closed_count += 1
        @ready << true
        @release.pop
      end
    end

    class CloseCountingOutput
      attr_reader :closed_count

      def initialize
        @closed_count = 0
      end

      def write(_value); end

      def close
        @closed_count += 1
      end
    end

    def test_close_only_closes_pipeline_captured_before_concurrent_reconfigure
      context = close_race_context

      configure_close_race_start(context)
      close_thread = Thread.new { Julewire.close(timeout: 5) }

      assert context.fetch(:handle_ready).pop(timeout: 1)

      reconfigure_during_close(context)
      context.fetch(:release_handle) << true

      assert close_thread.value
      assert_equal 1, context.fetch(:old_output).closed_count
      assert_equal 0, context.fetch(:new_output).closed_count
    ensure
      context&.fetch(:release_handle)&.push(true)
      cleanup_thread(close_thread)
    end

    def test_close_is_idempotent_for_pipeline_lifecycle
      output = CloseCountingOutput.new
      Julewire.configure do |config|
        configure_destination(config, output: output, close_output: true)
      end

      assert Julewire.close(timeout: 1)
      assert Julewire.close(timeout: 1)

      assert_equal 1, output.closed_count
    end

    def test_configure_after_close_does_not_close_old_pipeline_again
      old_output = CloseCountingOutput.new
      new_output = CloseCountingOutput.new
      Julewire.configure do |config|
        configure_destination(config, output: old_output, close_output: true)
      end

      assert Julewire.close(timeout: 1)
      Julewire.configure do |config|
        configure_destination(config, output: new_output, close_output: true)
      end

      assert_equal 1, old_output.closed_count
      assert_equal 0, new_output.closed_count
    end

    private

    def close_race_context
      handle_ready = Queue.new
      release_handle = Queue.new
      {
        handle_ready: handle_ready,
        release_handle: release_handle,
        old_output: BlockingCloseOutput.new(ready: handle_ready, release: release_handle),
        new_output: CloseCountingOutput.new
      }
    end

    def configure_close_race_start(context)
      Julewire.configure do |config|
        configure_destination(config, output: context.fetch(:old_output), close_output: true)
      end
    end

    def reconfigure_during_close(context)
      Julewire.configure do |config|
        configure_destination(config, output: context.fetch(:new_output), close_output: true)
      end
    end
  end
end
