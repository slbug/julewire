# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestPropagationRestore < Minitest::Test
    def test_propagation_restore_feeds_context_and_execution_into_next_scope
      envelope = captured_operation_envelope

      restored_execution = nil
      restored_context = nil
      restored_carry = nil

      Julewire::Core::Propagation.restore(envelope) do
        Julewire.with_execution(type: :active_job, fields: { job_id: "job-1" }) do
          restored_execution = Julewire.current_execution.execution_hash
          restored_context = Julewire.context.to_h
          restored_carry = Julewire.carry.to_h
        end
      end

      assert_equal "trace-1", restored_execution[:trace_id]
      assert_equal "cor-1", restored_execution[:correlation_id]
      assert_equal "eu", restored_execution[:tenant_region]
      assert_equal "job-1", restored_execution[:job_id]
      assert_equal "tenant-1", restored_context[:tenant_id]
      assert_equal "trace-1", restored_carry.dig(:http, :request_headers, :traceparent)
    end

    def test_propagation_restore_resets_new_execution_lineage_by_default
      envelope = captured_operation_envelope(id: "operation-1")
      restored_execution = nil

      Julewire::Core::Propagation.restore(envelope) do
        Julewire.with_execution(type: :active_job, id: "job-1", emit_summary: false) do
          restored_execution = Julewire.current_execution.execution_hash
        end
      end

      assert_equal 1, restored_execution[:depth]
      assert_equal({ type: "active_job", id: "job-1" }, restored_execution[:root])
      refute_includes restored_execution, :parent
    end

    def test_propagation_restore_can_link_new_execution_lineage
      envelope = captured_operation_envelope(id: "operation-1")
      restored_execution = nil
      restored_lineage = nil

      Julewire::Core::Propagation.restore(envelope, link_executions: true) do
        restored_execution, restored_lineage = capture_active_job_execution
      end

      assert_equal 2, restored_execution[:depth]
      assert_equal({ type: "operation", id: "operation-1" }, restored_execution[:root])
      assert_equal({ type: "operation", id: "operation-1" }, restored_execution[:parent])
      assert_equal [{ type: "operation", id: "operation-1" }], restored_lineage.ancestors
    end

    def test_nested_unlinked_restore_resets_outer_linked_lineage
      outer = captured_operation_envelope(id: "operation-1")
      inner = { execution: { span_id: "span-1" } }
      restored_execution = nil
      restored_lineage = nil

      Julewire::Core::Propagation.restore(outer, link_executions: true) do
        Julewire::Core::Propagation.restore(inner) do
          restored_execution, restored_lineage = capture_active_job_execution
        end
      end

      assert_equal "trace-1", restored_execution[:trace_id]
      assert_equal "span-1", restored_execution[:span_id]
      assert_equal 1, restored_execution[:depth]
      assert_equal({ type: "active_job", id: "job-1" }, restored_execution[:root])
      refute_includes restored_execution, :parent
      assert_empty restored_lineage.ancestors
    end

    def test_propagation_restore_works_across_threads
      envelope = nil

      Julewire.with_execution(type: :operation, fields: { trace_id: "trace-1" }) do
        Julewire.context.add(tenant_id: "tenant-1")
        envelope = Julewire::Core::Propagation.capture
      end

      restored_context, restored_execution = Thread.new do
        Julewire::Core::Propagation.restore(envelope) do
          Julewire.with_execution(type: :active_job, fields: { job_id: "job-1" }, emit_summary: false) do
            [Julewire.context.to_h, Julewire.current_execution.execution_hash]
          end
        end
      end.value

      assert_equal "tenant-1", restored_context[:tenant_id]
      assert_equal "trace-1", restored_execution[:trace_id]
      assert_equal "job-1", restored_execution[:job_id]
    end

    def test_propagation_capture_keeps_restored_execution_snapshot
      envelope = {
        context: { "tenant_id" => "tenant-1" },
        carry: { "http" => { "request_headers" => { "traceparent" => "trace-1" } } },
        execution: { "trace_id" => "trace-1" }
      }
      recaptured = nil

      Julewire::Core::Propagation.restore(envelope) do
        recaptured = Julewire.thread { Julewire::Core::Propagation.capture }.value
      end

      assert_equal "tenant-1", recaptured.dig(:context, "tenant_id")
      assert_equal "trace-1", recaptured.dig(:carry, "http", "request_headers", "traceparent")
      assert_equal "trace-1", recaptured.dig(:execution, "trace_id")
    end

    def test_propagation_restore_accepts_nil_envelope
      context = Julewire::Core::Propagation.restore(nil) do
        Julewire.context.to_h
      end

      assert_empty context
    end

    def test_restored_string_keys_do_not_duplicate_later_symbol_context_keys
      envelope = { context: { "tenant_id" => "from-envelope" } }
      restored = nil

      Julewire::Core::Propagation.restore(envelope) do
        with_julewire_job do
          Julewire.context.add(tenant_id: "from-context")
          restored = Julewire.context.to_h
        end
      end

      assert_equal({ tenant_id: "from-context" }, restored)
    end

    def test_nested_propagation_restores_outer_execution_overlay
      outer = { context: { tenant_id: "tenant-1" }, execution: { trace_id: "trace-1" } }
      inner = { context: { job_context: "inner" }, execution: { span_id: "span-1" } }
      inside_inner = nil
      after_inner = nil

      Julewire::Core::Propagation.restore(outer) do
        Julewire::Core::Propagation.restore(inner) do
          Julewire.with_execution(type: :inner, emit_summary: false) do
            inside_inner = current_context_and_execution
          end
        end

        Julewire.with_execution(type: :outer, emit_summary: false) do
          after_inner = current_context_and_execution
        end
      end

      actual = [
        inside_inner.first,
        inside_inner.last.values_at(:trace_id, :span_id),
        after_inner.first,
        after_inner.last.values_at(:trace_id, :span_id)
      ]

      assert_equal nested_propagation_state, actual
    end

    def test_propagation_restore_cleans_up_after_exception
      envelope = { context: { leaked: true }, execution: { trace_id: "trace-1" } }

      assert_raises(RuntimeError) do
        Julewire::Core::Propagation.restore(envelope) do
          raise "boom"
        end
      end

      assert_empty Julewire.context.to_h
      with_julewire_job do
        refute_includes Julewire.current_execution.execution_hash, :trace_id
      end
    end

    def test_propagation_restore_inside_existing_execution_adds_temporary_context
      envelope = { context: { "request_id" => "request-1" }, execution: { "trace_id" => "trace-1" } }
      inside_restore = nil
      after_restore = nil

      Julewire.with_execution(type: :outer, id: "outer", emit_summary: false) do
        Julewire.context.add(tenant_id: "tenant-1")

        Julewire::Core::Propagation.restore(envelope) do
          inside_restore = current_context_and_execution
        end

        after_restore = current_context_and_execution
      end

      assert_equal({ tenant_id: "tenant-1", request_id: "request-1" }, inside_restore.first)
      assert_equal "outer", inside_restore.last[:id]
      assert_equal({ tenant_id: "tenant-1" }, after_restore.first)
      refute_includes after_restore.last, :trace_id
    end

    def test_nested_execution_inherits_parent_execution_without_propagation_overlay
      child_execution = nested_request_job_execution

      assert_equal "tenant-1", child_execution[:tenant_id]
      assert_equal "job-1", child_execution[:id]
      assert_equal "request-1", child_execution.dig(:parent, :id)
    end

    def test_nested_execution_merges_propagation_overlay_inside_existing_execution
      child_execution = nested_request_job_execution(envelope: { execution: { "trace_id" => "trace-1" } })

      assert_equal "tenant-1", child_execution[:tenant_id]
      assert_equal "trace-1", child_execution[:trace_id]
      assert_equal "job-1", child_execution[:id]
      assert_equal "request-1", child_execution.dig(:parent, :id)
    end

    private

    def nested_request_job_execution(envelope: nil)
      child_execution = nil
      Julewire.with_execution(type: :request, id: "request-1", fields: { tenant_id: "tenant-1" },
                              emit_summary: false) do
        run_with_optional_restore(envelope) do
          Julewire.with_execution(type: :job, id: "job-1", emit_summary: false) do
            child_execution = Julewire.current_execution.execution_hash
          end
        end
      end
      child_execution
    end

    def run_with_optional_restore(envelope, &)
      envelope ? Julewire::Core::Propagation.restore(envelope, &) : yield
    end

    def current_context_and_execution
      [Julewire.context.to_h, Julewire.current_execution.execution_hash]
    end

    def capture_active_job_execution
      Julewire.with_execution(type: :active_job, id: "job-1", emit_summary: false) do
        execution = Julewire.current_execution
        [execution.execution_hash, execution.lineage]
      end
    end

    def nested_propagation_state
      [
        { tenant_id: "tenant-1", job_context: "inner" },
        %w[trace-1 span-1],
        { tenant_id: "tenant-1" },
        ["trace-1", nil]
      ]
    end

    def captured_operation_envelope(id: nil)
      Julewire.with_execution(
        type: :operation,
        id: id,
        fields: {
          trace_id: "trace-1",
          correlation_id: "cor-1",
          tenant_region: "eu"
        }
      ) do
        Julewire.context.add(tenant_id: "tenant-1")
        Julewire.carry.add(http: { request_headers: { traceparent: "trace-1" } })
        Julewire::Core::Propagation.capture
      end
    end
  end
end
