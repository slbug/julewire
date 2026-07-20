# frozen_string_literal: true

require "test_helper"
require "json"

module Julewire
  class TestConcurrencyWrappers < Minitest::Test
    cover "Julewire::Ractor::Bridge.spawn_ractor"
    cover "Julewire::Ractor::Bridge.start"
    cover "Julewire::Ractor::Bridge.start_bridge"
    cover "Julewire::Ractor::RemoteRuntime#start_execution"
    cover "Julewire::Ractor::RemoteRuntime#emit_integration"
    cover "Julewire::Ractor::RemoteRuntime#remote_emit"
    class QueueingOutput
      def initialize
        @records = Queue.new
      end

      def write(value) = @records << value

      def pop(timeout: 1)
        @records.pop(timeout: timeout)
      end
    end

    def test_ractor_wrapper_bridges_emits_to_parent_runtime
      with_experimental_ractor_warnings_suppressed do
        output = configured_ractor_output
        emit_from_nested_concurrency_boundaries

        assert_ractor_record(record_after_flush(output))
      end
    end

    def test_ractor_wrapper_bridges_emits_to_parent_output_after_flush
      with_experimental_ractor_warnings_suppressed do
        output = configured_ractor_output

        emit_from_nested_concurrency_boundaries

        assert_true Julewire.flush(timeout: 1)
        assert_ractor_record(JSON.parse(safe_queue_pop(output)))
      end
    end

    def test_ractor_wrapper_preserves_owned_truncation_metadata
      with_experimental_ractor_warnings_suppressed do
        output = QueueingOutput.new
        Julewire.configure { configure_direct_destination(it, output: output) }
        encoded = Julewire::Core::Propagation::Carrier.encode(envelope: { context: { blob: "x" * 20_000 } })

        Julewire::Core::Propagation::Carrier.restore({ "julewire" => encoded }) do
          Julewire.ractor do
            Julewire.emit(severity: :error, source: "app", event: "work", message: "done")
          end.value
        end

        assert_true Julewire.flush(timeout: 1)
        assert_truncated_context(JSON.parse(safe_queue_pop(output)).fetch("context"))
      end
    end

    def test_ractor_wrapper_bridges_execution_summaries_to_parent_runtime
      with_experimental_ractor_warnings_suppressed do
        output = emit_ractor_summary
        record = record_after_flush(output)

        assert_ractor_summary_record(record)
      end
    end

    def test_start_execution_run_inside_ractor_finishes_without_isolation_error
      with_experimental_ractor_warnings_suppressed do
        output = QueueingOutput.new
        Julewire.configure { configure_direct_destination(it, output: output) }

        Julewire.ractor do
          Julewire.start_execution(type: :unit, id: "u-1").run { Julewire.emit(message: "in-run") }
        end.value

        assert_equal "in-run", JSON.parse(safe_queue_pop(output)).fetch("message")
      end
    end

    def test_ractor_wrapper_propagates_context_and_emits_point_and_summary
      output = QueueingOutput.new
      formatter = :to_h.to_proc
      traceparent = "00-06796866738c859f2f19b7cfb3214824-000000000000004a-01"

      with_experimental_ractor_warnings_suppressed do
        Julewire.configure { configure_direct_destination(it, formatter: formatter, output: output) }
        Julewire.context.add(request_id: "request-1")
        Julewire.carry.add(http: { request_headers: { traceparent: traceparent } })
        Julewire.ractor do
          Julewire.with_execution(
            type: :contract,
            id: "contract-1",
            summary_event: "contract.completed",
            summary_source: "contract"
          ) do
            Julewire.summary.add(total: 2)
            Julewire.emit(event: "contract.point", source: "contract", message: "point", payload: { value: 1 })
          end
        end.value

        assert_true Julewire.flush(timeout: 1)

        records = Array.new(2) { JSON.parse(safe_queue_pop(output)) }
        point = records.find { it.fetch("event") == "contract.point" }
        summary = records.find { it.fetch("event") == "contract.completed" }

        assert_equal "point", point.fetch("message")
        assert_equal "request-1", point.dig("context", "request_id")
        assert_equal traceparent, point.dig("carry", "http", "request_headers", "traceparent")
        assert_equal 2, summary.dig("payload", "total")
        assert_equal "contract", summary.fetch("source")
        assert_equal :ok, Julewire.health.fetch(:status)
      end
    end

    def test_ractor_wrapper_preserves_string_message_shorthand
      with_experimental_ractor_warnings_suppressed do
        output = QueueingOutput.new
        Julewire.configure { configure_direct_destination(it, output: output) }

        Julewire.ractor { Julewire.emit("done") }.value

        assert_equal "done", record_after_flush(output).fetch("message")
      end
    end

    def test_ractor_wrapper_normalizes_public_string_keys_before_the_owned_bridge
      with_experimental_ractor_warnings_suppressed do
        output = QueueingOutput.new
        Julewire.configure { configure_direct_destination(it, output: output) }

        Julewire.ractor do
          Julewire.emit("message" => "done", "custom" => { "nested" => 1 })
        end.value

        record = record_after_flush(output)

        assert_equal "done", record.fetch("message")
        assert_equal 1, record.dig("payload", "custom", "nested")
      end
    end

    def test_ractor_integration_emits_keep_the_owned_symbol_contract
      with_experimental_ractor_warnings_suppressed do
        output = QueueingOutput.new
        Julewire.configure { configure_direct_destination(it, output: output) }

        stats = Julewire.ractor do
          Julewire::Core::Integration::Facade.emit(event: "integration.valid", payload: { token: "kept" })
          Julewire::Core::Integration::Facade.emit(event: "integration.invalid", payload: { "token" => "lost" })
          Julewire::Core::Integration::Facade.emit(event: "integration.unknown", custom: :lost)
          Julewire::Ractor.child_stats
        end.value

        record = record_after_flush(output)

        assert_equal "integration.valid", record.fetch("event")
        assert_equal "kept", record.dig("payload", "token")
        assert_equal 1, stats.dig(:counts, :messages_sent)
        assert_equal 2, stats.dig(:counts, :messages_dropped)
        assert_equal "TypeError", stats.fetch(:last_error_class)
      end
    end

    def test_ractor_wrapper_preserves_severity_helpers
      with_experimental_ractor_warnings_suppressed do
        output = QueueingOutput.new
        Julewire.configure { configure_direct_destination(it, output: output) }

        Julewire.ractor { Julewire.error("boom", event: "ractor.error") }.value

        record = record_after_flush(output)

        assert_equal "error", record.fetch("severity")
        assert_equal "boom", record.fetch("message")
        assert_equal "ractor.error", record.fetch("event")
      end
    end

    def test_ractor_integration_emit_can_bypass_the_parent_level_gate
      with_experimental_ractor_warnings_suppressed do
        output = QueueingOutput.new
        Julewire.configure do |config|
          config.level = :fatal
          configure_direct_destination(config, output: output)
        end

        Julewire.ractor do
          Julewire::Core::Integration::Facade.emit(severity: :debug, message: "filtered")
          Julewire::Core::Integration::Facade.emit(
            { severity: :debug, message: "bypassed" }, enforce_level: false
          )
        end.value

        record = record_after_flush(output)

        assert_equal "debug", record.fetch("severity")
        assert_equal "bypassed", record.fetch("message")
      end
    end

    def test_ractor_wrapper_evaluates_lazy_emit_blocks
      with_experimental_ractor_warnings_suppressed do
        output = QueueingOutput.new
        Julewire.configure { configure_direct_destination(it, output: output) }

        Julewire.ractor do
          Julewire.info { { message: "lazy", payload: { value: 1 } } }
        end.value

        record = record_after_flush(output)

        assert_equal "info", record.fetch("severity")
        assert_equal "lazy", record.fetch("message")
        assert_equal 1, record.dig("payload", "value")
      end
    end

    def test_ractor_wrapper_contains_and_counts_public_emit_failures
      with_experimental_ractor_warnings_suppressed do
        Julewire.configure { configure_direct_destination(it, output: QueueingOutput.new) }

        stats = Julewire.ractor do
          Julewire.emit { raise ArgumentError, "invalid public input" }
          Julewire::Ractor.child_stats
        end.value

        assert_equal 0, stats.dig(:counts, :messages_sent)
        assert_equal 1, stats.dig(:counts, :messages_dropped)
        assert_equal "ArgumentError", stats.fetch(:last_error_class)
      end
    end

    def test_wrappers_require_blocks
      assert_raises(ArgumentError) { Julewire.thread }
      assert_raises(ArgumentError) { Julewire.fiber }
      assert_raises(ArgumentError) { Julewire.ractor }
    end

    def test_ractor_wrapper_requires_experimental_opt_in
      with_overridden_singleton_method(Julewire::Ractor::Bridge, :enabled?, proc { false }) do
        error = assert_raises(Julewire::Core::Error) do
          Julewire.ractor { :unused }
        end

        assert_match(/enable_experimental_ractor!/, error.message)
      end
    end

    private

    def record_after_flush(output)
      assert_true Julewire.flush(timeout: 1)
      JSON.parse(safe_queue_pop(output))
    end

    def configured_ractor_output
      QueueingOutput.new.tap do |output|
        Julewire.configure do |config|
          config.level = :warn
          configure_direct_destination(config, output: output)
          config.labels.add(app: "core-test")
        end
        Julewire.context.add(request_id: "request-1")
      end
    end

    def emit_from_nested_concurrency_boundaries
      thread = safe_julewire_thread do
        Julewire.context.add(worker: "thread")
        Julewire.ractor do
          Julewire.context.add(ractor_worker: "ractor")
          Julewire.fiber do
            Julewire.context.add(fiber_worker: "fiber")
            Julewire.emit(severity: :error, source: "app", event: "work", message: "done")
          end.resume
        end.value
      end
      safe_thread_value(thread)
    end

    def assert_ractor_record(record)
      context = record.fetch("context")

      assert_equal "error", record.fetch("severity")
      assert_equal "done", record.fetch("message")
      assert_equal "core-test", record.fetch("labels").fetch("app")
      assert_equal "request-1", context.fetch("request_id")
      assert_equal "thread", context.fetch("worker")
      assert_equal "ractor", context.fetch("ractor_worker")
      assert_equal "fiber", context.fetch("fiber_worker")
    end

    def with_experimental_ractor_warnings_suppressed
      Julewire.enable_experimental_ractor!
      without_bridge_monitor do
        return yield unless Warning.respond_to?(:[])

        previous = Warning[:experimental]
        Warning[:experimental] = false
        yield
      ensure
        Warning[:experimental] = previous if defined?(previous)
      end
    end

    def without_bridge_monitor(&)
      with_overridden_singleton_method(Julewire::Ractor::Bridge, :monitor_ractor, proc { |*_arguments| false }, &)
    end

    def emit_ractor_summary
      QueueingOutput.new.tap do |output|
        Julewire.configure { configure_direct_destination(it, output: output) }
        Julewire.context.add(request_id: "request-1")
        Julewire.carry.add(http: { request_headers: { traceparent: "trace-1" } })
        Julewire.ractor do
          Julewire.with_execution(type: :job) do
            Julewire.context.add(worker: "ractor")
            Julewire.carry.add(worker: { id: "ractor" })
            Julewire.summary.add(processed: 1)
          end
        end.value
      end
    end

    def assert_ractor_summary_record(record)
      assert_equal "summary", record.fetch("kind")
      assert_equal "job.completed", record.fetch("event")
      assert_equal "request-1", record.dig("context", "request_id")
      assert_equal "ractor", record.dig("context", "worker")
      assert_false record.key?("carry")
      assert_equal 1, record.dig("payload", "processed")
    end

    def assert_truncated_context(context)
      assert_match(/\Ax+\.\.\.\[Truncated\]\z/, context.fetch("blob"))
      metadata = context.fetch("_julewire_truncation")

      assert_true metadata.fetch("truncated")
      assert_equal ["blob"], metadata.fetch("truncated_fields")
      assert_equal Julewire::Core::Serialization::Serializer::DEFAULT_MAX_STRING_BYTES,
                   metadata.dig("limits", "max_string_bytes")
    end
  end
end
