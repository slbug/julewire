# frozen_string_literal: true

require_relative "../../../support/testing/coverage"
Julewire::TestSupport::Coverage.start!

require "julewire/ractor"

require "timeout"

require "minitest/autorun"
require "minitest/strict"
require_relative "../../../support/testing/method_override"
require_relative "../../../support/testing/test_reports"
Julewire::TestSupport::TestReports.start!
require_relative "../../../support/mutant/minitest_coverage"

module Minitest
  class Test
    include Julewire::TestSupport::MethodOverride

    def setup
      Julewire.reset!
      Julewire::Ractor::Bridge.reset!
    end

    def configure_direct_destination(
      config,
      output:,
      encoder: Julewire::Core::Serialization::JsonEncoder.new,
      formatter: Julewire::Core::Records::Formatter.new,
      name: :default
    )
      config.destinations.add(
        Julewire::Core::Destinations::Destination.new(
          name: name,
          close_output: false,
          encoder: encoder,
          formatter: formatter,
          max_record_bytes: Julewire::Core::DEFAULT_MAX_RECORD_BYTES,
          on_drop: config.on_drop,
          on_failure: config.on_failure,
          output: output,
          processors: []
        )
      )
    end

    def safe_thread(*, &block)
      build_safe_thread(block) { |worker| Thread.new(*, &worker) }
    end

    def safe_julewire_thread(*, &block)
      build_safe_thread(block) { |worker| Julewire.thread(*, &worker) }
    end

    def build_safe_thread(block)
      raise ArgumentError, "block required" unless block

      worker = proc do |*thread_arguments|
        Thread.current.abort_on_exception = false
        Thread.current.report_on_exception = false
        block.call(*thread_arguments)
      rescue Exception => e # rubocop:disable Lint/RescueException -- Re-raised by the owning test after bounded join.
        Thread.current.thread_variable_set(:julewire_test_worker_exception, e)
        nil
      end
      yield worker
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

    def bounded_ractor_operation(timeout: 2, &)
      Timeout.timeout(timeout, &)
    end

    def cleanup_thread(thread, timeout: 0)
      return unless thread
      return if thread.join(Float(timeout))

      thread.kill
      thread.join(0.1)
    end

    def cleanup_ractor_destination(destination)
      return unless destination

      command_port = destination.instance_variable_get(:@port)
      worker = destination.instance_variable_get(:@worker)
      ack_port = destination.instance_variable_get(:@ack_port)
      ack_thread = destination.instance_variable_get(:@ack_thread)
      cleanup_ractor_worker(command_port, worker)
    ensure
      cleanup_thread(ack_thread) if defined?(ack_thread)
      Julewire::Ractor::PortLifecycle.close(ack_port) if defined?(ack_port)
    end

    def cleanup_ractor_worker(command_port, worker)
      command_port&.send({ command: :close_worker })
    rescue ::Ractor::ClosedError, ::Ractor::RemoteError
      nil
    ensure
      wait_for_ractor_cleanup(worker) if worker
    end

    def nonblocking_queue_values(queue) = Array.new(queue.size) { queue.pop(true) }

    def receive_ractor(port, timeout: 1)
      selected, value = select_ractor(port, timeout: timeout)
      flunk "timed out waiting for ractor port message" unless selected.equal?(port)

      value
    end

    def select_ractor(*ports, timeout: 1)
      Timeout.timeout(timeout) { ::Ractor.select(*ports) }
    rescue Timeout::Error
      flunk "timed out waiting for ractor port message"
    end

    def with_temporary_constant(owner, name, value)
      existed = owner.const_defined?(name, false)
      previous = owner.const_get(name, false) if existed
      owner.__send__(:remove_const, name) if existed
      owner.const_set(name, value)
      yield
    ensure
      owner.__send__(:remove_const, name) if owner.const_defined?(name, false)
      owner.const_set(name, previous) if existed
    end

    private

    def wait_for_ractor_cleanup(worker)
      Timeout.timeout(1) { worker.value }
    rescue StandardError
      nil
    end
  end
end
