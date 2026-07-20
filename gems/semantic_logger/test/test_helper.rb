# frozen_string_literal: true

require_relative "../../../support/testing/coverage"
Julewire::TestSupport::Coverage.start!

require "julewire/semantic_logger"

require "minitest/autorun"
require "minitest/strict"
require_relative "../../../support/testing/test_reports"
Julewire::TestSupport::TestReports.start!
require_relative "../../../support/mutant/minitest_coverage"
require "stringio"
require "timeout"

module Minitest
  class Test
    def safe_thread(*)
      raise ArgumentError, "block required" unless block_given?

      Thread.new(*) do |*thread_arguments|
        Thread.current.abort_on_exception = false
        Thread.current.report_on_exception = false
        yield(*thread_arguments)
      rescue Exception => e # rubocop:disable Lint/RescueException -- Re-raised by the owning test after bounded join.
        Thread.current.thread_variable_set(:julewire_test_worker_exception, e)
        nil
      end
    end

    def safe_thread_value(thread, timeout: 1)
      unless thread.join(Float(timeout))
        cleanup_thread(thread)

        flunk "thread did not finish within #{timeout} seconds"
      end

      value = thread.value
      error = thread.thread_variable_get(:julewire_test_worker_exception)
      raise error if error

      value
    end

    def safe_thread_values(threads, timeout: 1)
      threads.map { safe_thread_value(it, timeout: timeout) }
    end

    def safe_queue_pop(queue, timeout: 1)
      Timeout.timeout(timeout) { queue.pop }
    end

    def cleanup_thread(thread, timeout: 0)
      return unless thread
      return if thread.join(Float(timeout))

      thread.kill
      thread.join(0.1)
    end

    def setup
      Julewire.reset!
    end
  end
end
