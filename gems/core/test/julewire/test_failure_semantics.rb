# frozen_string_literal: true

require "test_helper"
require "json"
require "stringio"

module Julewire
  class TestFailureSemantics < Minitest::Test
    cover Julewire::Core::Diagnostics::InternalRecords
    cover Julewire::Core::Execution::Boundary
    cover "Julewire::Core::Runtime#build_execution_boundary"
    cover "Julewire::Core::Runtime#emit"
    cover "Julewire::Core::Runtime#emit_non_standard_exception_summaries?"
    cover "Julewire::Core::Runtime#handle_summary_finalizer_failure"
    cover "Julewire::Core::Runtime#initialize"
    cover "Julewire::Core::Runtime#summary_finalizer_failure"
    cover "Julewire::Core::Runtime#with_execution"
    def test_summary_emit_failures_do_not_mask_user_exceptions
      output = Class.new do
        def write(_value)
          raise "write failed"
        end
      end.new

      Julewire.configure do |config|
        configure_destination(config, output: output)
      end

      error = assert_raises(RuntimeError) do
        Julewire.with_execution(type: :active_job) do
          raise "user failure"
        end
      end

      assert_equal "user failure", error.message
    end

    def test_execution_summary_skips_non_standard_exception_unwinds_by_default
      output = StringIO.new

      Julewire.configure do |config|
        configure_destination(config, output: output)
      end

      assert_raises(SystemExit) do
        Julewire.with_execution(type: :job) do
          raise SystemExit
        end
      end

      assert_empty output.string
    end

    def test_execution_summary_can_opt_into_non_standard_exception_unwinds
      output = StringIO.new

      Julewire.configure do |config|
        configure_destination(config, output: output)
        config.emit_non_standard_exception_summaries = true
      end

      assert_raises(SystemExit) do
        Julewire.with_execution(type: :job) do
          raise SystemExit
        end
      end

      record = JSON.parse(output.string)

      assert_equal "error", record.fetch("severity")
      assert_equal "SystemExit", record.dig("error", "class")
    end

    def test_new_runtime_execution_summary_can_opt_into_non_standard_exception_unwinds
      runtime = Julewire::Core::Runtime.new
      output = StringIO.new
      runtime.configure do |config|
        configure_destination(config, output: output)
        config.emit_non_standard_exception_summaries = true
      end

      assert_raises(SystemExit) do
        runtime.with_execution(type: :job) { raise SystemExit }
      end

      record = JSON.parse(output.string)

      assert_equal "error", record.fetch("severity")
      assert_equal "SystemExit", record.dig("error", "class")
    ensure
      runtime&.close
    end

    def test_execution_summary_classifies_arbitrary_non_standard_exception_unwinds
      output = StringIO.new

      Julewire.configure do |config|
        configure_destination(config, output: output)
        config.emit_non_standard_exception_summaries = true
      end

      assert_raises(NoMemoryError) do
        Julewire.with_execution(type: :job) do
          raise NoMemoryError, "fatal"
        end
      end

      record = JSON.parse(output.string)

      assert_equal "error", record.fetch("severity")
      assert_equal "NoMemoryError", record.dig("error", "class")
    end

    def test_execution_summary_skips_arbitrary_non_standard_exception_unwinds_by_default
      output = StringIO.new

      Julewire.configure { configure_destination(it, output: output) }

      assert_raises(NoMemoryError) do
        Julewire.with_execution(type: :job) do
          raise NoMemoryError, "fatal"
        end
      end

      assert_empty output.string
    end

    def test_new_runtime_execution_summary_skips_non_standard_exception_unwinds_by_default
      runtime = Julewire::Core::Runtime.new
      output = StringIO.new
      runtime.configure { configure_destination(it, output: output) }

      assert_raises(SystemExit) do
        runtime.with_execution(type: :job) { raise SystemExit }
      end

      assert_empty output.string
    ensure
      runtime&.close
    end

    def test_summary_finalizer_failures_are_reported_to_runtime_failure_hook
      runtime_class = Class.new(Julewire::Core::Runtime) do
        def emit_summary_record(_scope)
          raise "summary failed"
        end
      end
      runtime = runtime_class.new
      failures = configure_runtime_failure_capture(runtime)

      runtime.with_execution(type: :job) { :done }

      error, metadata = failures.pop(timeout: 1)

      assert_equal "summary failed", error.message
      assert_equal :summary_emit, metadata.fetch(:phase)
    end

    def test_context_store_finalizer_failure_callback_is_best_effort
      result = Julewire::Core::ContextStore.current.with_execution(
        type: :job,
        on_finish: ->(_scope) { raise "finish failed" },
        on_finish_failure: ->(_error, **) { raise "callback failed" }
      ) { :ok }

      assert_equal :ok, result
    end

    def test_emit_prunes_circular_payloads_without_raising
      output = StringIO.new
      Julewire.configure do |config|
        configure_destination(config, output: output)
      end
      cycle = {}
      cycle[:self] = cycle

      Julewire.emit(payload: cycle)

      record = JSON.parse(output.string)

      assert_equal "[Circular]", record.dig("payload", "self")
      assert_false record.fetch("payload").key?("_julewire_truncation")
    end

    def test_processor_failures_emit_minimal_internal_error_records
      output = StringIO.new
      failing_processor = Class.new do
        def call(_record)
          raise "broken"
        end
      end

      pipeline = build_pipeline(
        processors: [failing_processor.new],
        output: output
      )
      pipeline.emit(message: "contains secret", payload: { password: "unfiltered" })

      record = JSON.parse(output.string)

      assert_equal "julewire.processor_error", record["event"]
      assert_equal "error", record["severity"]
      assert_equal "Julewire processor failed", record["message"]
      assert_equal "RuntimeError", record.dig("payload", "error", "class")
      refute_includes record.dig("payload", "error"), "message"
      assert_equal "log", record.dig("payload", "record", "event")
      refute_includes output.string, "unfiltered"
      refute_includes output.string, "contains secret"
    end

    def test_internal_emit_error_record_contract
      error = Class.new(StandardError).new("hidden")

      record = Julewire::Core::Diagnostics::InternalRecords.emit_error(error).to_record.to_h

      assert_equal :error, record.fetch(:severity)
      assert_equal :point, record.fetch(:kind)
      assert_equal "julewire.emit_error", record.fetch(:event)
      assert_equal "julewire", record.fetch(:source)
      assert_equal "Julewire emit failed", record.fetch(:message)
      assert_equal({}, record.fetch(:context))
      assert_equal({}, record.fetch(:labels))
      assert_equal({}, record.fetch(:execution))
      assert_equal({}, record.fetch(:attributes))
      assert_equal({}, record.fetch(:neutral))
      assert_equal({}, record.fetch(:carry))
      assert_equal({}, record.dig(:payload, :error))
      refute_includes record.fetch(:payload).inspect, "hidden"
    end

    def test_internal_processor_error_record_contract
      error = RuntimeError.new("secret-token")
      labels = Class.new(Hash).new.merge!(service: "billing")
      metadata = {
        event: "work.failed",
        labels: labels,
        severity: :warn
      }

      record = Julewire::Core::Diagnostics::InternalRecords.processor_error(
        processor_name: "Redactor",
        error: error,
        record_metadata: metadata
      ).to_record.to_h

      assert_equal :error, record.fetch(:severity)
      assert_equal :point, record.fetch(:kind)
      assert_equal "julewire.processor_error", record.fetch(:event)
      assert_equal "julewire", record.fetch(:source)
      assert_equal "Julewire processor failed", record.fetch(:message)
      assert_equal({ service: "billing" }, record.fetch(:labels))
      assert_equal "Redactor", record.dig(:payload, :processor)
      assert_equal({ class: "RuntimeError" }, record.dig(:payload, :error))
      assert_equal metadata, record.dig(:payload, :record)
      refute_includes record.fetch(:payload).inspect, "secret-token"
    end

    def test_internal_processor_error_ignores_non_hash_labels
      record = Julewire::Core::Diagnostics::InternalRecords.processor_error(
        processor_name: "Processor",
        error: RuntimeError.new("hidden"),
        record_metadata: { labels: "bad labels" }
      ).to_record.to_h

      assert_equal({}, record.fetch(:labels))

      record = Julewire::Core::Diagnostics::InternalRecords.processor_error(
        processor_name: "Processor",
        error: RuntimeError.new("hidden"),
        record_metadata: {}
      ).to_record.to_h

      assert_equal({}, record.fetch(:labels))
    end

    def test_failure_hook_observes_contained_pipeline_failures
      failures = Queue.new
      failing_formatter = Class.new do
        def call(_record)
          raise "format failed"
        end
      end

      Julewire.configure do |config|
        configure_destination(config, formatter: failing_formatter.new, output: StringIO.new)
        config.on_failure = ->(error, _metadata) { failures << error }
      end

      assert_nil Julewire.emit(message: "contained")

      assert_equal "format failed", safe_queue_pop(failures).message
    end
  end
end
