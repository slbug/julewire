# frozen_string_literal: true

require "test_helper"
require "json"
require "stringio"

module Julewire
  class TestConcurrencyWrappers < Minitest::Test # rubocop:disable Metrics/ClassLength
    class QueueingOutput
      def initialize
        @records = Queue.new
      end

      def write(value) = @records << value

      def pop(timeout: 1)
        @records.pop(timeout: timeout)
      end
    end

    def test_thread_wrapper_propagates_context_and_execution_overlay
      assert_wrapper_propagates_context_and_execution(worker: "thread") do |&block|
        Julewire.thread(&block).value
      end
    end

    def test_fiber_wrapper_propagates_context_and_execution_overlay
      assert_wrapper_propagates_context_and_execution(worker: "fiber") do |&block|
        Julewire.fiber(&block).resume
      end
    end

    def test_thread_and_fiber_wrappers_preserve_local_ruby_values
      Julewire.context.add(role: :admin)

      thread_role = Julewire.thread { Julewire.context[:role] }.value
      fiber_role = Julewire.fiber { Julewire.context[:role] }.resume

      assert_equal :admin, thread_role
      assert_equal :admin, fiber_role
    end

    def test_ractor_uses_shared_julewire_integration_spi_contract
      assert_julewire_integration_spi_contract
    end

    def test_thread_wrapper_applies_propagated_execution_to_direct_emits
      output = QueueingOutput.new
      Julewire.configure { configure_direct_destination(it, output: output) }

      Julewire.with_execution(type: :request, fields: { trace_id: "trace-1" }, emit_summary: false) do
        Julewire.thread { Julewire.emit(message: "direct") }.join
      end

      record = JSON.parse(output.pop)

      assert_equal "trace-1", record.dig("execution", "trace_id")
      assert_equal "request", record.dig("execution", "type")
    end

    def test_ractor_wrapper_bridges_emits_to_parent_runtime
      with_experimental_ractor_warnings_suppressed do
        output = configured_ractor_output
        emit_from_nested_concurrency_boundaries

        assert_ractor_record(JSON.parse(output.pop))
      end
    end

    def test_ractor_wrapper_bridges_emits_to_parent_output_after_flush
      with_experimental_ractor_warnings_suppressed do
        output = configured_ractor_output

        emit_from_nested_concurrency_boundaries

        assert Julewire.flush(timeout: 1)
        assert_ractor_record(JSON.parse(output.pop))
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

        assert Julewire.flush(timeout: 1)
        assert_truncated_context(JSON.parse(output.pop).fetch("context"))
      end
    end

    def test_ractor_wrapper_bridges_execution_summaries_to_parent_runtime
      with_experimental_ractor_warnings_suppressed do
        output = emit_ractor_summary
        record = JSON.parse(output.pop)

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

        assert_equal "in-run", JSON.parse(output.pop).fetch("message")
      end
    end

    def test_ractor_wrapper_satisfies_execution_boundary_contract
      with_experimental_ractor_warnings_suppressed do
        output = QueueingOutput.new
        formatter = :to_h.to_proc

        point, summary, health = assert_julewire_execution_boundary_contract(
          configure: ->(config) { configure_direct_destination(config, formatter: formatter, output: output) },
          exercise: method(:exercise_ractor_boundary_contract),
          records: -> { Array.new(2) { JSON.parse(output.pop) } },
          event_path: %w[event],
          context_path: %w[context],
          carry_path: %w[carry],
          summary_payload_path: %w[payload]
        )

        assert_equal "point", point.fetch("message")
        assert_equal "contract", summary.fetch("source")
        assert_equal :ok, health.fetch(:status)
      end
    end

    def test_ractor_wrapper_preserves_string_message_shorthand
      with_experimental_ractor_warnings_suppressed do
        output = QueueingOutput.new
        Julewire.configure { configure_direct_destination(it, output: output) }

        Julewire.ractor { Julewire.emit("done") }.value

        assert_equal "done", JSON.parse(output.pop).fetch("message")
      end
    end

    def test_ractor_wrapper_preserves_severity_helpers
      with_experimental_ractor_warnings_suppressed do
        output = QueueingOutput.new
        Julewire.configure { configure_direct_destination(it, output: output) }

        Julewire.ractor { Julewire.error("boom", event: "ractor.error") }.value

        record = JSON.parse(output.pop)

        assert_equal "error", record.fetch("severity")
        assert_equal "boom", record.fetch("message")
        assert_equal "ractor.error", record.fetch("event")
      end
    end

    def test_ractor_wrapper_can_emit_without_parent_level_gate
      with_experimental_ractor_warnings_suppressed do
        output = QueueingOutput.new
        Julewire.configure do |config|
          config.level = :fatal
          configure_direct_destination(config, output: output)
        end

        Julewire.ractor do
          Julewire::Core::RuntimeLocator.current.emit_without_level(severity: :debug, message: "debug")
        end.value

        record = JSON.parse(output.pop)

        assert_equal "debug", record.fetch("severity")
        assert_equal "debug", record.fetch("message")
      end
    end

    def test_ractor_wrapper_evaluates_lazy_emit_blocks
      with_experimental_ractor_warnings_suppressed do
        output = QueueingOutput.new
        Julewire.configure { configure_direct_destination(it, output: output) }

        Julewire.ractor do
          Julewire.info { { message: "lazy", payload: { value: 1 } } }
        end.value

        record = JSON.parse(output.pop)

        assert_equal "info", record.fetch("severity")
        assert_equal "lazy", record.fetch("message")
        assert_equal 1, record.dig("payload", "value")
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

    def assert_wrapper_propagates_context_and_execution(worker:, &run)
      context, execution = Julewire.with_execution(
        type: :request,
        fields: { trace_id: "trace-1" },
        emit_summary: false
      ) do
        Julewire.context.add(request_id: "request-1")

        run.call do
          Julewire.context.add(worker: worker)
          Julewire.with_execution(type: :worker, emit_summary: false) do
            [Julewire.context.to_h, Julewire.current_execution.execution_hash]
          end
        end
      end

      assert_equal "request-1", context[:request_id]
      assert_equal worker, context[:worker]
      assert_equal "trace-1", execution[:trace_id]
      assert_equal "worker", execution[:type]
      assert_empty Julewire.context.to_h
    end

    def exercise_ractor_boundary_contract(**)
      Julewire.context.add(request_id: "request-1")
      Julewire.carry.add(
        http: {
          request_headers: {
            traceparent: "00-06796866738c859f2f19b7cfb3214824-000000000000004a-01"
          }
        }
      )
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
      Julewire.thread do
        Julewire.context.add(worker: "thread")
        Julewire.ractor do
          Julewire.context.add(ractor_worker: "ractor")
          Julewire.fiber do
            Julewire.context.add(fiber_worker: "fiber")
            Julewire.emit(severity: :error, source: "app", event: "work", message: "done")
          end.resume
        end.value
      end.join
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
      return yield unless Warning.respond_to?(:[])

      previous = Warning[:experimental]
      Warning[:experimental] = false
      yield
    ensure
      Warning[:experimental] = previous if defined?(previous)
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
      refute record.key?("carry")
      assert_equal 1, record.dig("payload", "processed")
    end

    def assert_truncated_context(context)
      assert_match(/\Ax+\.\.\.\[Truncated\]\z/, context.fetch("blob"))
      metadata = context.fetch("_julewire_truncation")

      assert metadata.fetch("truncated")
      assert_equal ["blob"], metadata.fetch("truncated_fields")
      assert_equal Julewire::Core::Serialization::Serializer::DEFAULT_MAX_STRING_BYTES,
                   metadata.dig("limits", "max_string_bytes")
    end
  end
end
