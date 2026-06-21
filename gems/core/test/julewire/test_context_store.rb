# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestContextStore < Minitest::Test
    cover Julewire::Core::Fields::FieldStack

    def test_scope_context_overrides_ambient_context_only_inside_scope
      Julewire.context.add(correlation_id: "ambient", account_id: "acct-1")

      inside = nil
      with_julewire_job do
        Julewire.context.add(correlation_id: "scope")
        inside = Julewire.context.to_h
      end

      assert_equal "scope", inside[:correlation_id]
      assert_equal "acct-1", inside[:account_id]
      assert_equal({ correlation_id: "ambient", account_id: "acct-1" }, Julewire.context.to_h)
    end

    def test_thread_contexts_are_isolated
      Julewire.context.add(main: true)

      results = Array.new(2) do |index|
        Thread.new do
          Julewire.with_execution(type: :worker, id: "worker-#{index}", emit_summary: false) do
            Julewire.context.add(worker: index)
            [Julewire.context.to_h, Julewire.current_execution.id]
          end
        end
      end.map(&:value)

      assert_equal [[{ worker: 0 }, "worker-0"], [{ worker: 1 }, "worker-1"]], results
      assert_equal({ main: true }, Julewire.context.to_h)
    end

    def test_fiber_contexts_are_isolated
      Julewire.context.add(main: true)

      inside_fiber = Fiber.new { Julewire.context.to_h }.resume

      assert_empty inside_fiber
      assert_equal({ main: true }, Julewire.context.to_h)
    end

    def test_reset_clears_current_context
      Julewire.context.add(account_id: "acct-1")

      Julewire.reset!

      assert_nil Thread.current[context_store_thread_key]
      assert_empty Julewire.context.to_h
    end

    def test_main_runtime_context_does_not_use_thread_symbol_storage
      Julewire.context.add(account_id: "acct-1")

      assert_nil Thread.current[context_store_thread_key]
      assert_equal({ account_id: "acct-1" }, Julewire.context.to_h)
    end

    def test_reset_from_one_thread_does_not_clear_another_thread_context
      ready = Queue.new
      resume_worker = Queue.new
      worker_context = Queue.new

      worker = Thread.new do
        Julewire.context.add(worker_id: "worker-1")
        ready << true
        resume_worker.pop
        worker_context << Julewire.context.to_h
      end

      ready.pop
      Julewire.context.add(main: true)
      Julewire.reset!
      resume_worker << true

      assert_equal({ worker_id: "worker-1" }, worker_context.pop)
      worker.join

      assert_empty Julewire.context.to_h
    end

    def test_context_lookup_preserves_false_and_normalizes_string_ingress
      Julewire.context.add(enabled: false, empty: nil, "tenant_id" => "tenant-1")

      assert_same false, Julewire.context[:enabled]
      assert_same false, Julewire.context["enabled"]
      assert_nil Julewire.context[:empty]
      assert_equal "tenant-1", Julewire.context[:tenant_id]
      assert_equal "tenant-1", Julewire.context["tenant_id"]
      assert_nil Julewire.context[:missing]
      assert_nil Julewire.context["missing"]
      assert_nil Julewire.context[Object.new]
    end

    def test_context_add_prunes_circular_hashes
      cycle = {}
      cycle[:self] = cycle

      Julewire.context.add(cycle: cycle)

      assert_equal "[Circular]", Julewire.context.to_h.dig(:cycle, :self)
    end

    def test_context_add_defensively_copies_caller_hashes
      fields = { account: { id: "acct-1" } }

      Julewire.context.add(fields)
      fields[:account][:id] = "changed"

      assert_equal "acct-1", Julewire.context.to_h.dig(:account, :id)
    end

    def test_context_add_wraps_non_hash_values_without_raising
      Julewire.context.add("request-context", tenant_id: "tenant-1")

      assert_equal "request-context", Julewire.context[:value]
      assert_equal "tenant-1", Julewire.context[:tenant_id]
    end

    def test_context_overlay_replaces_same_top_level_field_for_lookup_snapshot_and_records
      records = configure_record_capture
      Julewire.context.add(account: { id: "acct-1", plan: "free" }, other: { id: "other" })

      Julewire.context.with(account: { plan: "pro" }) do
        assert_equal({ plan: "pro" }, Julewire.context[:account])
        assert_equal({ plan: "pro" }, Julewire.context.to_h.fetch(:account))
        Julewire.emit(message: "inside")
      end

      assert_equal({ plan: "pro" }, records.fetch(0).dig(:context, :account))
      assert_equal({ id: "acct-1", plan: "free" }, Julewire.context[:account])
    end

    def test_context_lookup_handles_scope_only_and_scalar_override
      Julewire.context.add(tenant_id: "ambient")

      with_julewire_job do
        Julewire.context.add(request_id: "request-1")

        assert_equal "request-1", Julewire.context[:request_id]

        Julewire.context.with(tenant_id: nil) do
          assert_nil Julewire.context[:tenant_id]
        end
      end
    end

    def test_carry_lookup_applies_delete_masks_to_requested_field
      Julewire.carry.add(http: { request_headers: { traceparent: "trace", authorization: "secret" } })
      Julewire.carry.delete(:http, :request_headers, :authorization)

      assert_equal({ request_headers: { traceparent: "trace" } }, Julewire.carry[:http])
    end

    def test_carry_lookup_handles_no_delete_and_top_level_delete
      Julewire.carry.add(trace: { id: "trace-1" })

      assert_equal({ id: "trace-1" }, Julewire.carry[:trace])

      Julewire.carry.delete(:trace)

      assert_nil Julewire.carry[:trace]
    end

    def test_ambient_context_overlay_defensively_copies_caller_hashes
      assert_context_overlay_defensively_copies_caller_hashes do |fields, capture|
        Julewire.context.with(fields) { capture.call }
      end
    end

    def test_scope_context_overlay_defensively_copies_caller_hashes
      assert_context_overlay_defensively_copies_caller_hashes do |fields, capture|
        with_julewire_job do
          Julewire.context.with(fields) { capture.call }
        end
      end
    end

    def test_context_overlay_failed_copy_does_not_pop_existing_overlay
      store = Julewire::Core::ContextStore.current
      scenarios = [context_overlay_failure_scenario(store)]

      with_julewire_job do
        scope = Julewire::Core::ContextStore.current.current_scope
        scenarios << context_overlay_failure_scenario(scope)
      end

      scenarios.each { |outer, inner, context| assert_broken_overlay_copy_preserves_context(outer, inner, context) }
    end

    def test_propagation_failed_context_copy_does_not_pop_existing_overlays
      store = Julewire::Core::ContextStore.current

      store.with_propagation(context: { outer: true }, execution: { trace_id: "trace-1" }) do
        assert_raises(RuntimeError) do
          store.with_propagation(context: BrokenHash[bad: true], execution: { span_id: "span-1" }) { :unused }
        end

        assert_equal({ outer: true }, store.context_hash)
        assert_equal "trace-1", store.current_scope_or_snapshot.execution_hash[:trace_id]
      end
    end

    def test_propagation_snapshot_reuses_effective_execution_until_overlay_changes
      store = Julewire::Core::ContextStore.current

      store.with_propagation(execution: { trace_id: "trace-1", root: { type: "request", id: "req-1" } }) do
        first = store.current_scope_or_snapshot.execution_hash
        second = store.current_scope_or_snapshot.execution_hash

        assert_equal first, second
        assert_equal "trace-1", second[:trace_id]
        assert_equal "request", second.dig(:root, :type)

        store.with_propagation(execution: { span_id: "span-1" }) do
          nested = store.current_scope_or_snapshot.execution_hash

          assert_equal "trace-1", nested[:trace_id]
          assert_equal "span-1", nested[:span_id]
        end

        assert_equal second, store.current_scope_or_snapshot.execution_hash
      end
    end

    def test_linked_propagation_snapshot_still_parents_new_executions
      store = Julewire::Core::ContextStore.current

      store.with_propagation(execution: { type: "request", id: "request-1" }, link_executions: true) do
        store.with_execution(type: :job, id: "job-1") do |execution|
          assert_equal 2, execution.execution_hash[:depth]
          assert_equal "request-1", execution.execution_hash.dig(:parent, :id)
        end
      end
    end

    private

    class BrokenHash < Hash
      def each(*)
        raise "copy failed"
      end
    end

    def context_store_thread_key
      Julewire::Core::LocalStorage.__send__(:const_get, :CONTEXT_STORE_THREAD_KEY)
    end

    def assert_broken_overlay_copy_preserves_context(outer, inner, context)
      outer.call do
        assert_raises(RuntimeError) { inner.call }

        assert_equal({ outer: true }, context.call)
      end
    end

    def context_overlay_failure_scenario(target)
      [
        ->(&block) { target.with_context(outer: true, &block) },
        -> { target.with_context(BrokenHash[bad: true]) },
        -> { target.context_hash }
      ]
    end

    def assert_context_overlay_defensively_copies_caller_hashes
      fields = { account: { id: "acct-1" } }
      inside = nil
      capture = lambda do
        fields[:account][:id] = "changed"
        inside = Julewire.context.to_h
      end

      yield fields, capture

      assert_equal "acct-1", inside.dig(:account, :id)
    end
  end
end
