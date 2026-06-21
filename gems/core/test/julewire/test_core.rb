# frozen_string_literal: true

require "test_helper"
require "json"
require "stringio"

module Julewire
  class TestCore < Minitest::Test
    def test_that_it_has_a_version_number
      assert_match(/\A\d+\.\d+\.\d+\z/, ::Julewire::Core::VERSION)
    end

    def test_zeitwerk_eager_loads_core_tree
      Julewire::Core.__send__(:loader).eager_load(force: true)

      assert Julewire::Core.const_defined?(:VERSION)
    end

    def test_core_singleton_methods_are_internal
      refute_respond_to Julewire::Core, :configure
      assert_respond_to Julewire, :configure
      assert_respond_to Julewire, :runtime
      assert_respond_to Julewire, :flush
      assert_respond_to Julewire, :close
      assert(%i[health after_fork!].all? { Julewire.respond_to?(it) })
      refute_respond_to Julewire, :reopen
      refute_respond_to Julewire, :install_at_exit_close
      assert Julewire::Core.singleton_class.private_method_defined?(:loader)
      refute_respond_to Julewire::Core, :loader
      refute_respond_to Julewire, :pipeline
      refute_respond_to Julewire, :pipeline=
    end

    def test_named_runtimes_have_independent_pipelines
      default_output = StringIO.new
      audit_output = StringIO.new

      Julewire.configure { configure_destination(it, output: default_output) }
      Julewire.runtime(:audit).configure { configure_destination(it, output: audit_output) }

      Julewire.emit(message: "default")
      Julewire.runtime(:audit).emit(message: "audit")

      assert_includes default_output.string, "default"
      refute_includes default_output.string, "audit"
      assert_includes audit_output.string, "audit"
      refute_includes audit_output.string, "default"
    end

    def test_named_runtime_is_memoized
      assert_same Julewire.runtime(:audit), Julewire.runtime("audit")
      assert_same Julewire::Core::RuntimeLocator.current, Julewire.runtime
      assert_same Julewire::Core::RuntimeLocator.current, Julewire.runtime(:default)
    end

    def test_named_runtime_rejects_bad_names
      assert_raises(ArgumentError) { Julewire.runtime(Object.new) }
      assert_raises(ArgumentError) { Julewire.runtime("") }
    end

    def test_named_sentinels_are_frozen_and_readable
      sentinel = Julewire::Core.sentinel(:example)

      assert_predicate sentinel, :frozen?
      assert_equal :example, sentinel.name
      assert_equal "#<Julewire::Core::Sentinel example>", sentinel.inspect
    end

    def test_named_runtime_requires_core_runtime
      current = Object.new

      Julewire::Core::RuntimeLocator.current = current

      assert_same current, Julewire.runtime
      error = assert_raises(Julewire::Core::Error) { Julewire.runtime(:audit) }
      assert_match "named Julewire runtimes", error.message
    ensure
      Julewire::Core::RuntimeLocator.current = Julewire::Core::Runtime.new
    end

    def test_public_extension_aliases_point_to_core_contract_classes
      assert_same Julewire::Core::Records::Record, Julewire::Record
      assert_same Julewire::Core::Records::Draft, Julewire::RecordDraft
      assert_same Julewire::Core::Records::ConsoleFormatter, Julewire::ConsoleFormatter
      assert_same Julewire::Core::Records::Formatter, Julewire::RecordFormatter
      assert_same Julewire::Core::Serialization::JsonEncoder, Julewire::JsonEncoder
      assert_same Julewire::Core::Serialization::TextEncoder, Julewire::TextEncoder
      assert_same Julewire::Core::Serialization::Serializer, Julewire::Serializer
      assert_same Julewire::Core::Processing::Match, Julewire::Match
      refute Julewire.const_defined?(:CLI, false)
      refute Julewire.const_defined?(:Destination, false)
      refute Julewire.const_defined?(:MetaObserver, false)
      refute Julewire.const_defined?(:Severity, false)
    end

    def test_capture_julewire_records_collects_normalized_records
      records = capture_julewire_records do
        Julewire.emit(message: "hello", payload: { count: 1 })
      end

      assert_equal "hello", records.first[:message]
      assert_equal 1, records.first.dig(:payload, :count)
    end

    def test_context_add_is_included_on_point_logs_and_summary_logs
      output = StringIO.new
      Julewire.configure do |config|
        configure_destination(config, output: output)
      end

      Julewire.with_execution(type: :operation, fields: { operation_id: "op-1" }) do
        Julewire.context.add(tenant_id: "tenant-1")
        Julewire.summary.add(plan: "pro")
        Julewire.emit(message: "hello", payload: { token: "secret" })
      end

      point = JSON.parse(output.string.lines.first)

      expected_point = %w[hello tenant-1 op-1 secret]
      actual_point = [
        point["message"], point.dig("context", "tenant_id"),
        point.dig("execution", "operation_id"), point.dig("payload", "token")
      ]

      assert_equal expected_point, actual_point

      summary = JSON.parse(output.string.lines.last)

      actual_summary = [summary["kind"], summary.dig("context", "tenant_id"), summary.dig("payload", "plan")]

      assert_equal %w[summary tenant-1 pro], actual_summary
      assert_in_delta 0, summary.dig("metrics", "duration_ms"), 1000
    end

    def test_context_with_cleans_up_after_the_block
      Julewire.context.add(account_id: "acct-1")

      inside = nil
      Julewire.context.with(order_id: "order-1") do
        inside = Julewire.context.to_h
      end
      outside = Julewire.context.to_h

      assert_equal "acct-1", inside[:account_id]
      assert_equal "order-1", inside[:order_id]
      assert_equal({ account_id: "acct-1" }, outside)
    end

    def test_concurrent_configure_calls_are_serialized
      ready = Queue.new
      start = Queue.new
      outputs = Array.new(2) { StringIO.new }

      threads = outputs.each_with_index.map do |output, index|
        Thread.new do
          ready << true
          start.pop
          Julewire.configure do |config|
            configure_destination(config, output: output)
            config.labels.add(worker: index)
          end
        end
      end

      2.times { ready.pop }
      2.times { start << true }
      threads.each(&:value)

      Julewire.emit(message: "configured")

      written_outputs = outputs.select { it.string.include?("configured") }

      assert_equal 1, written_outputs.length
    end

    def test_summary_requires_an_execution_scope
      refute_predicate Julewire.summary, :active?

      error = assert_raises(Julewire::Core::Execution::NoCurrentError) do
        Julewire.summary.add(total: 1)
      end

      assert_match "current execution", error.message
    end

    def test_health_reports_runtime_generation
      before = Julewire.health

      Julewire.configure { configure_destination(it, output: StringIO.new) }

      after = Julewire.health

      assert_operator after.fetch(:generation), :>, before.fetch(:generation)
    end

    def test_summary_reports_active_inside_execution_scope
      refute_predicate Julewire, :current_execution?

      Julewire.with_execution(type: :request, emit_summary: false) do
        assert_predicate Julewire.summary, :active?
        assert_predicate Julewire, :current_execution?
      end

      refute_predicate Julewire, :current_execution?
    end

    def test_execution_scope_finishes_with_error_on_exception
      records = capture_julewire_records do
        assert_raises(RuntimeError) do
          Julewire.with_execution(type: :active_job) do
            raise "boom"
          end
        end
      end

      summary = records.detect { it[:kind] == :summary }

      assert_equal :error, summary[:severity]
      assert_equal "RuntimeError", summary.dig(:error, :class)
    end

    def test_propagation_envelope_excludes_summary_data
      envelope = capture_propagation(
        type: :active_job,
        execution: { trace_id: "trace-1", correlation_id: "cor-1" },
        context: { tenant_id: "tenant-1" },
        carry: { http: { request_headers: { traceparent: "trace-1" } } },
        summary: { response_plan: "pro" }
      )

      assert_equal "tenant-1", envelope.dig(:context, "tenant_id")
      assert_equal "trace-1", envelope.dig(:carry, "http", "request_headers", "traceparent")
      assert_equal "trace-1", envelope.dig(:execution, "trace_id")
      refute_includes envelope.fetch(:context), "response_plan"
    end

    def test_json_encoder_serializes_guarded_formatter_values
      cyclic = {}
      cyclic[:self] = cyclic

      record = JSON.parse(
        Julewire::Core::Serialization::JsonEncoder.new.call(
          Julewire::Core::Records::Formatter.new.call(
            build_record(
              { timestamp: Time.utc(2026, 1, 1), payload: { cyclic: cyclic, symbol: :value } },
              context: {},
              scope: nil
            )
          )
        )
      )

      assert_equal "2026-01-01T00:00:00.000000000Z", record.fetch("timestamp")
      assert_equal "[Circular]", record.dig("payload", "cyclic", "self")
      assert_equal "value", record.dig("payload", "symbol")
    end
  end

  class TestConfigureGuard < Minitest::Test
    def test_julewire_fiber_created_inside_configure_does_not_keep_stale_guard
      output = StringIO.new
      fiber = nil

      Julewire.configure do |config|
        configure_destination(config, output: output)
        fiber = Julewire.fiber { Julewire.emit(message: "fiber") }
      end

      fiber.resume

      assert_equal "fiber", JSON.parse(output.string).fetch("message")
    end

    def test_julewire_thread_created_inside_configure_does_not_keep_stale_guard
      output = StringIO.new
      ready = Queue.new
      thread = nil

      Julewire.configure do |config|
        configure_destination(config, output: output)
        thread = Julewire.thread do
          ready.pop
          Julewire.emit(message: "thread")
        end
      end

      ready << true
      thread.value

      assert_equal "thread", JSON.parse(output.string).fetch("message")
    end

    def test_configure_guard_reaches_nested_fibers
      Julewire.configure do |_config|
        Fiber.new do
          error = assert_raises(Julewire::Core::Error) do
            Julewire.emit(message: "nested")
          end

          assert_match "cannot be called from inside Julewire.configure", error.message
        end.resume
      end
    end

    def test_raw_thread_spawned_inside_configure_can_emit_after_configure_finishes
      output = StringIO.new
      release = Queue.new
      result = Queue.new
      thread = nil

      Julewire.configure do |config|
        configure_destination(config, output: output)
        thread = Thread.new do
          release.pop
          Julewire.emit(message: "raw-thread")
          result << :ok
        rescue StandardError => e
          result << e
        end
      end

      release << true
      emitted = result.pop

      assert_equal :ok, emitted
      assert_equal "raw-thread", JSON.parse(output.string).fetch("message")
    ensure
      cleanup_thread(thread)
    end
  end

  class TestCoreRuntimeHooks < Minitest::Test
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

    def test_after_fork_resets_process_local_warning_state
      Julewire.configure do |config|
        configure_destination(config, output: FailingOutput.new)
      end

      Julewire.emit(severity: Object.new, message: "bad severity")

      before = Julewire.health

      assert_operator before.dig(:counts, :invalid_record_severities), :>, 0

      Julewire.after_fork!

      after = Julewire.health

      assert_equal 0, after.dig(:counts, :invalid_record_severities)
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

    def test_after_fork_forwards_to_outputs_and_registered_integration_hooks
      output = ForkAwareOutput.new
      hook_calls = 0
      Julewire::Core::Integration::Lifecycle.register_after_fork(:test_core, component: :test) { hook_calls += 1 }
      Julewire.configure do |config|
        configure_destination(config, output: output)
      end

      Julewire.after_fork!

      assert_equal 1, output.after_fork_count
      assert_equal 1, hook_calls
    ensure
      Julewire::Core::Integration::ForkHooks.reset!
    end

    def test_after_fork_forwards_to_named_runtime_outputs_once
      default_output = ForkAwareOutput.new
      audit_output = ForkAwareOutput.new
      hook_calls = 0
      Julewire::Core::Integration::Lifecycle.register_after_fork(:test_core, component: :test) { hook_calls += 1 }

      Julewire.configure { configure_destination(it, output: default_output) }
      Julewire.runtime(:audit).configure { configure_destination(it, output: audit_output) }

      Julewire.after_fork!

      assert_equal 1, default_output.after_fork_count
      assert_equal 1, audit_output.after_fork_count
      assert_equal 1, hook_calls
    ensure
      Julewire::Core::Integration::ForkHooks.reset!
    end

    def test_after_fork_keeps_multiple_components_for_one_integration
      calls = []
      Julewire::Core::Integration::Lifecycle.register_after_fork(:test_core, component: :first) { calls << :first }
      Julewire::Core::Integration::Lifecycle.register_after_fork(:test_core, component: :second) { calls << :second }

      Julewire.after_fork!

      assert_equal %i[first second], calls
    ensure
      Julewire::Core::Integration::ForkHooks.reset!
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
      Julewire::Core::Integration::Lifecycle.register_after_fork(:test_core, component: :after_fork) do
        raise "hook failed"
      end

      Julewire.after_fork!

      health = Julewire.health.fetch(:process_integrations).fetch(:test_core)

      assert_equal :degraded, health.fetch(:status)
      assert_equal :after_fork, health.dig(:last_failure, :action)
      assert_equal :after_fork, health.dig(:last_failure, :component)
    ensure
      Julewire::Core::Integration::ForkHooks.reset!
    end

    def test_after_fork_registration_rejects_programmer_errors
      assert_raises_message(ArgumentError, /block required/) do
        Julewire::Core::Integration::Lifecycle.register_after_fork(:test_core, component: :after_fork)
      end

      assert_raises_message(ArgumentError, /integration name/) do
        Julewire::Core::Integration::Lifecycle.register_after_fork("", component: :after_fork) { nil }
      end
    ensure
      Julewire::Core::Integration::ForkHooks.reset!
    end

    def test_after_fork_rebuilds_process_local_storage_mutexes
      local_storage_mutex = Julewire::Core::LocalStorage.instance_variable_get(:@runtime_mutex)
      integration_store = Julewire::Core::Diagnostics::ProcessIntegrationHealth.instance_variable_get(:@store)

      Julewire.after_fork!

      refute_same local_storage_mutex, Julewire::Core::LocalStorage.instance_variable_get(:@runtime_mutex)
      refute_same integration_store, Julewire::Core::Diagnostics::ProcessIntegrationHealth.instance_variable_get(:@store)
    end

    def test_runtime_locator_uses_local_storage_in_main_ractor
      skip "Ractor-local storage is not available" unless ractor_storage_available?

      runtime = Julewire::Core::Runtime.new

      Julewire::Core::RuntimeLocator.current = runtime

      assert_same runtime, Julewire::Core::RuntimeLocator.current
      assert_same runtime, Julewire::Core::LocalStorage.runtime
    end

    def test_runtime_level_emit_failures_notify_failure_callback
      failures = Queue.new
      configure_runtime_failure_capture(failures)
      previous_runtime_failures = Julewire.health.dig(:counts, :runtime_failures)
      pipeline = active_pipeline

      with_overridden_singleton_method(pipeline, :emit, proc { |_record, **| raise "escaped pipeline failure" }) do
        assert_nil Julewire.emit(message: "lost")
      end

      assert_equal "escaped pipeline failure", failures.pop.message
      assert_runtime_failure_recorded(previous_runtime_failures)
      assert_runtime_status_recovers_after_successful_emit
    end

    def test_runtime_level_emit_failure_callback_failures_are_counted
      Julewire.configure do |config|
        config.on_failure = ->(_error, _metadata) { raise "callback failed" }
      end
      pipeline = active_pipeline
      previous_counts = Julewire.health.fetch(:counts)

      with_overridden_singleton_method(pipeline, :emit, proc { |_record, **| raise "escaped pipeline failure" }) do
        assert_nil Julewire.emit(message: "lost")
      end

      health = Julewire.health

      actual_delta = health.dig(:counts, :runtime_callback_failures) -
                     previous_counts.fetch(:runtime_callback_failures)
      runtime_failure_delta = health.dig(:counts, :runtime_failures) -
                              previous_counts.fetch(:runtime_failures)

      assert_equal 1, actual_delta
      assert_equal 1, runtime_failure_delta
    end

    def test_runtime_level_emit_failures_use_callback_from_emit_state
      original_failures = Queue.new
      replacement_failures = Queue.new
      Julewire.configure do |config|
        config.on_failure = ->(error, _metadata) { original_failures << error }
      end
      pipeline = active_pipeline

      with_overridden_singleton_method(
        pipeline,
        :emit,
        proc do |_record, **|
          Julewire.configure do |config|
            config.on_failure = ->(error, _metadata) { replacement_failures << error }
          end
          raise "snapshot pipeline failure"
        end
      ) do
        assert_nil Julewire.emit(message: "lost")
      end

      assert_equal "snapshot pipeline failure", original_failures.pop.message
      assert_empty nonblocking_queue_values(replacement_failures)
    end

    private

    def ractor_storage_available?
      defined?(Ractor) &&
        Ractor.respond_to?(:store_if_absent) &&
        Ractor.respond_to?(:[])
    end

    def active_pipeline
      Julewire::Core::RuntimeLocator.current.__send__(:runtime_state).pipeline
    end

    def configure_runtime_failure_capture(failures)
      Julewire.configure do |config|
        config.destinations.use(:default, output: StringIO.new)
        config.on_failure = ->(error, _metadata) { failures.push(error) }
      end
    end

    def assert_runtime_failure_recorded(previous_runtime_failures)
      assert_equal 1, Julewire.health.dig(:counts, :runtime_failures) - previous_runtime_failures
      assert_equal "RuntimeError", Julewire.health.dig(:last_failure, :class)
      assert_equal :runtime, Julewire.health.dig(:last_failure, :phase)
    end

    def assert_runtime_status_recovers_after_successful_emit
      Julewire.emit(message: "recovered")

      assert_equal :ok, Julewire.health.fetch(:status)
      assert_equal "RuntimeError", Julewire.health.dig(:last_failure, :class)
    end
  end

  class TestCoreBlockContracts < Minitest::Test
    def test_public_block_apis_require_blocks
      assert_block_required { Julewire.with_execution(type: :job) }
      assert_block_required { Julewire.context.with(account_id: "acct-1") }
      assert_block_required { Julewire::Core::Propagation.restore({}) }
    end

    def assert_block_required(&)
      error = assert_raises(ArgumentError, &)

      assert_equal "block required", error.message
    end
  end

  class TestCoreConfigurationBoundaries < Minitest::Test
    def test_configure_rejects_runtime_calls_from_inside_configure
      old_config = Julewire.config

      assert_configure_rejects_runtime_call("Julewire.emit") { Julewire.emit(message: "not during configure") }

      assert_same old_config, Julewire.config
    end

    def test_configure_rejects_flush_from_inside_configure
      assert_configure_rejects_runtime_call("Julewire.flush") { Julewire.flush }
    end

    def test_configure_rejects_after_fork_from_inside_configure
      assert_configure_rejects_runtime_call("Julewire.after_fork!") { Julewire.after_fork! }
    end

    private

    def assert_configure_rejects_runtime_call(message)
      error = assert_raises(Julewire::Core::Error) do
        Julewire.configure do |config|
          config.level = :info
          yield
        end
      end

      assert_match message, error.message
    end
  end
end
