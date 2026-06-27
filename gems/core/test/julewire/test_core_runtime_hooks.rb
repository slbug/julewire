# frozen_string_literal: true

require "test_helper"
require "stringio"

module Julewire
  class TestCoreRuntimeHooks < Minitest::Test
    cover Julewire::Core::Integration::ForkHooks
    cover "Julewire::Core::Integration::Lifecycle.register_after_fork"
    cover "Julewire::Core::Runtime#after_fork!"
    cover "Julewire::Core::Runtime#with_emit_guard"
    cover "Julewire::Core::Runtime#reset_after_fork_runtime!"
    cover "Julewire::Core::Runtime#reset_after_fork_state!"
    cover "Julewire::Core::RuntimeRegistry.reset_after_fork"
    class FailingOutput
      def write(_value)
        raise "write failed"
      end
    end

    class ForkAwareOutput
      attr_reader :after_fork_count

      def initialize
        @after_fork_count = 0
      end

      def write(value)
        value.bytesize
      end

      def after_fork!
        @after_fork_count += 1
      end
    end

    class ForkFailingOutput
      def write(value)
        value.bytesize
      end

      def after_fork!
        raise "output fork failed"
      end
    end

    def test_configure_rejects_after_fork_from_inside_configure
      assert_runtime_call_rejected_inside_configure(:after_fork!) { Julewire.after_fork! }
    end

    def test_after_fork_resets_process_local_warning_state
      warnings = []
      Julewire.configure do |config|
        configure_destination(config, output: StringIO.new)
      end

      with_overridden_singleton_method(Warning, :warn, proc { |message| warnings << message }) do
        Julewire.emit(severity: Object.new, message: "before fork")

        before = Julewire.health

        assert_equal 1, before.dig(:counts, :invalid_record_severities)

        Julewire.after_fork!

        after = Julewire.health

        assert_equal 0, after.dig(:counts, :invalid_record_severities)

        Julewire.emit(severity: Object.new, message: "after fork")
      end

      assert_equal 2, warnings.length
      assert_equal 1, Julewire.health.dig(:counts, :invalid_record_severities)
    end

    def test_after_fork_replaces_pending_shared_scheduler_work
      events = Queue.new
      Julewire::Core::Scheduling::SharedScheduler.schedule(0.05) { events << :before_reset }

      Julewire.after_fork!
      Julewire::Core::Scheduling::SharedScheduler.schedule(0.01) { events << :after_reset }
      Julewire::Core::Scheduling::SharedScheduler.schedule(0.08) { events << :sentinel }

      assert_equal :after_reset, safe_queue_pop(events, timeout: 0.5)
      assert_equal :sentinel, safe_queue_pop(events, timeout: 0.5)
      assert_raises(ThreadError) { events.pop(true) }
    ensure
      Julewire::Core::Scheduling::SharedScheduler.after_fork!
    end

    def test_after_fork_resets_runtime_pipeline_and_destination_health
      Julewire.configure do |config|
        configure_destination(config, output: FailingOutput.new)
      end

      Julewire.emit(message: "lost")
      before = Julewire.health

      assert_equal :degraded, before.fetch(:status)
      assert_operator before.dig(:pipeline, :counts, :entered), :>, 0
      assert_operator before.dig(:pipeline, :destinations, :default, :counts, :output_error), :>, 0

      Julewire.after_fork!
      after = Julewire.health

      assert_equal :ok, after.fetch(:status)
      assert_equal 0, after.dig(:counts, :runtime_failures)
      assert_equal 0, after.dig(:pipeline, :counts, :entered)
      assert_equal 0, after.dig(:pipeline, :destinations, :default, :counts, :output_error)
      assert_nil after.dig(:pipeline, :destinations, :default, :last_loss)
    end

    def test_after_fork_resets_runtime_owned_health_and_counts
      runtime = Julewire.runtime
      runtime_failures_before = Julewire.health.dig(:counts, :runtime_failures)
      output = StringIO.new
      Julewire.configure { configure_destination(it, output: output) }

      runtime.emit_envelope(
        input: { "message" => "invalid owned envelope" },
        context: {},
        scope: nil,
        carry: {},
        attributes: {},
        neutral: {},
        owned: true
      )
      Julewire::Core::Integration::Health.record_failure(
        :test_core,
        RuntimeError.new("integration failed"),
        runtime: runtime,
        component: :runtime
      )
      Julewire.close(timeout: 1)
      Julewire.emit(message: "after close")

      before = Julewire.health

      assert_empty output.string
      assert_equal runtime_failures_before + 1, before.dig(:counts, :runtime_failures)
      assert_equal 1, before.dig(:counts, :post_close_emits)
      assert_equal :degraded, before.dig(:integrations, :test_core, :status)

      Julewire.after_fork!

      after = Julewire.health

      assert_nil after.fetch(:last_failure)
      assert_empty after.fetch(:integrations)
      assert_equal 0, after.dig(:counts, :runtime_failures)
      assert_equal 0, after.dig(:counts, :post_close_emits)
      assert_equal 0, after.dig(:counts, :post_close_emits_total)

      Julewire.configure { configure_destination(it, output: output) }
      Julewire.emit(message: "usable after fork")

      assert_includes output.string, "usable after fork"
    end

    def test_after_fork_resets_process_integration_health_and_remains_usable
      integration_health = Julewire::Core::Integration::Health
      integration_health.record_failure(
        :test_core,
        RuntimeError.new("process integration failed"),
        component: :process
      )

      assert_equal :degraded, Julewire.health.dig(:process_integrations, :test_core, :status)

      Julewire.after_fork!

      assert_empty Julewire.health.fetch(:process_integrations)

      integration_health.record_success(:test_core)

      assert_equal :ok, Julewire.health.dig(:process_integrations, :test_core, :status)
    end

    def test_after_fork_forwards_to_outputs_and_registered_integration_hooks
      output = ForkAwareOutput.new
      hook_calls = 0
      active = true
      Julewire::Core::Integration::Lifecycle.register_after_fork(:test_core, component: :test) do
        hook_calls += 1 if active
      end
      Julewire.configure do |config|
        configure_destination(config, output: output)
      end

      Julewire.after_fork!

      assert_equal 1, output.after_fork_count
      assert_equal 1, hook_calls
    ensure
      active = false
    end

    def test_after_fork_forwards_to_named_runtime_outputs_once
      default_output = ForkAwareOutput.new
      audit_output = ForkAwareOutput.new
      hook_calls = 0
      active = true
      Julewire::Core::Integration::Lifecycle.register_after_fork(:test_core, component: :test) do
        hook_calls += 1 if active
      end

      Julewire.configure { configure_destination(it, output: default_output) }
      Julewire.runtime(:audit).configure { configure_destination(it, output: audit_output) }

      Julewire.after_fork!

      assert_equal 1, default_output.after_fork_count
      assert_equal 1, audit_output.after_fork_count
      assert_equal 1, hook_calls
    ensure
      active = false
    end

    def test_after_fork_keeps_multiple_components_for_one_integration
      assert_after_fork_hooks(
        [%i[test_core first first], %i[test_core second second]]
      )
    end

    def test_after_fork_keeps_same_component_for_multiple_integrations
      assert_after_fork_hooks(
        [%i[first hook first], %i[second hook second]]
      )
    end

    def test_after_fork_contains_output_lifecycle_failures
      Julewire.configure do |config|
        configure_destination(config, output: ForkFailingOutput.new)
      end

      Julewire.after_fork!

      health = destination_health

      assert_equal :degraded, health.fetch(:status)
      assert_equal :after_fork, health.dig(:last_failure, :action)
      assert_equal :output_lifecycle, health.dig(:last_failure, :phase)
    end

    def test_after_fork_contains_registered_integration_hook_failures
      active = true
      Julewire::Core::Integration::Lifecycle.register_after_fork(:test_core, component: :after_fork) do
        raise "hook failed" if active
      end

      Julewire.after_fork!

      health = Julewire.health.fetch(:process_integrations).fetch(:test_core)

      assert_equal :degraded, health.fetch(:status)
      assert_equal :after_fork, health.dig(:last_failure, :action)
      assert_equal :after_fork, health.dig(:last_failure, :component)
      assert_equal "RuntimeError", health.dig(:last_failure, :class)
    ensure
      active = false
    end

    def test_after_fork_registration_rejects_string_protocol_names
      integration_error = assert_raises(TypeError) do
        Julewire::Core::Integration::Lifecycle.register_after_fork("test_core", component: :after_fork) { nil }
      end
      component_error = assert_raises(TypeError) do
        Julewire::Core::Integration::Lifecycle.register_after_fork(:test_core, component: "after_fork") { nil }
      end

      assert_equal "integration must be a Symbol", integration_error.message
      assert_equal "component must be a Symbol", component_error.message
    end

    def test_after_fork_runs_every_concurrently_registered_hook
      start = Queue.new
      calls = Queue.new
      active = true
      threads = Array.new(16) do |index|
        safe_thread do
          start.pop
          Julewire::Core::Integration::Lifecycle.register_after_fork(
            :test_core,
            component: :"hook_#{index}"
          ) { calls << index if active }
        end
      end

      16.times { start << true }
      safe_thread_values(threads)
      Julewire::Core::Integration::ForkHooks.run

      assert_equal (0...16).to_a, Array.new(16) { safe_queue_pop(calls) }.sort
      assert_raises(ThreadError) { calls.pop(true) }
    ensure
      active = false
      threads&.each { cleanup_thread(it) }
    end

    def test_after_fork_registration_rejects_integration_objects
      integration = Object.new
      integration.define_singleton_method(:to_s) { "test_core" }

      error = assert_raises(TypeError) do
        Julewire::Core::Integration::Lifecycle.register_after_fork(integration, component: :after_fork) { nil }
      end

      assert_equal "integration must be a Symbol", error.message
    end

    def test_after_fork_registration_rejects_programmer_errors
      assert_raises_message(ArgumentError, /block required/) do
        Julewire::Core::Integration::Lifecycle.register_after_fork(:test_core, component: :after_fork)
      end

      assert_raises_message(ArgumentError, "integration is required") do
        Julewire::Core::Integration::Lifecycle.register_after_fork(:"", component: :after_fork) { nil }
      end
    end

    def test_after_fork_preserves_runtime_and_clears_process_local_context
      runtime = Julewire::Core::LocalStorage.runtime
      Julewire.context.add(request_id: "req-1")

      Julewire.after_fork!

      assert_same runtime, Julewire::Core::LocalStorage.runtime
      assert_empty Julewire.context.to_h
    end

    # The ensure block owns real child-process and pipe cleanup.
    # rubocop:disable Minitest/SkipEnsure
    def test_local_storage_remains_usable_after_fork
      skip "Process.fork is unavailable" unless Process.respond_to?(:fork)

      local_storage = Julewire::Core::LocalStorage
      runtime = Julewire.runtime
      reader, writer = IO.pipe
      child_pid = Process.fork do
        reader.close
        Julewire.after_fork!
        local_storage.runtime = nil
        writer.write(Julewire.runtime.class.name)
        writer.close
        exit! 0
      rescue Exception => e # rubocop:disable Lint/RescueException -- Reports child bootstrap failures to the parent.
        writer.write("#{e.class}: #{e.message}")
        writer.close
        exit! 1
      end
      writer.close

      result = Timeout.timeout(1) { reader.read }
      _, status = Process.wait2(child_pid)
      child_pid = nil

      assert_predicate status, :success?, result
      assert_equal "Julewire::Core::Runtime", result
      assert_same runtime, Julewire.runtime
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

    def assert_after_fork_hooks(registrations)
      calls = []
      active = true
      registrations.each do |integration, component, value|
        Julewire::Core::Integration::Lifecycle.register_after_fork(integration, component:) do
          calls << value if active
        end
      end

      Julewire.after_fork!

      assert_equal registrations.map(&:last), calls
    ensure
      active = false
    end
  end
end
