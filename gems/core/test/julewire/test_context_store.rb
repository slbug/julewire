# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestContextStoreThreadIsolation < Minitest::Test
    cover "Julewire::Core::ContextStore#current_field_hash"

    def test_thread_contexts_are_isolated
      Julewire.context.add(main: true)

      threads = Array.new(2) do |index|
        safe_thread do
          Julewire.with_execution(type: :worker, id: "worker-#{index}", emit_summary: false) do
            Julewire.context.add(worker: index)
            [Julewire.context.to_h, Julewire.current_execution.id]
          end
        rescue StandardError => e
          e
        end
      end
      results = safe_thread_values(threads)
      errors = results.grep(StandardError)

      assert_empty errors
      assert_equal [[{ worker: 0 }, "worker-0"], [{ worker: 1 }, "worker-1"]], results
      assert_equal({ main: true }, Julewire.context.to_h)
    end
  end

  class TestContextStoreOwnedPropagation < Minitest::Test
    cover "Julewire::Core::ContextStore#with_propagation"

    def test_owned_propagation_rejects_nested_string_keys_before_yielding
      yielded = false
      store = Julewire::Core::ContextStore.new

      error = assert_raises(TypeError) do
        store.with_propagation(
          context: {},
          carry: {},
          execution: { parent: { "id" => "request-1" } },
          link_executions: true,
          owned: true
        ) { yielded = true }
      end

      assert_equal Julewire::Core::Fields::Internal::RECORD_STRING_KEY_ERROR, error.message
      assert_false yielded
    end
  end

  class TestContextStore < Minitest::Test
    cover Julewire::Core::ContextStore
    cover "Julewire::Core::Fields::AttributesProxy*"
    cover "Julewire::Core::Fields::CarryProxy*"
    cover "Julewire::Core::Fields::ContextProxy*"
    cover "Julewire::Core::Fields::SectionProxy*"
    cover "Julewire::Core::ContextStore#merged_execution_hash"
    cover "Julewire::Core::ContextStore#with_propagation"
    cover "Julewire::Core::Fields::SectionProxy#with"
    cover "Julewire::Core::Fields::CarryProxy#without"
    cover "Julewire::Core::Execution::Scope#with_field"
    cover "Julewire::Core::Execution::Scope#with_context"
    cover "Julewire::Core::ContextStore#build_scope"
    cover "Julewire::Core::ContextStore#with_execution"

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

    def test_context_store_with_execution_yields_public_view
      store = Julewire::Core::ContextStore.current

      view = store.with_execution(type: :job, emit_summary: false) { it }

      assert_instance_of Julewire::Core::Execution::View, view
      refute_respond_to view, :record_error
      assert_nil store.current_scope
    end

    def test_context_store_with_execution_records_active_exception_before_finish
      store = Julewire::Core::ContextStore.current
      summary_input = nil

      error = assert_raises(RuntimeError) do
        store.with_execution(
          type: :job,
          on_finish: ->(scope) { summary_input = scope.owned_summary_record_input },
          on_finish_failure: ->(_error, phase:) { flunk "unexpected #{phase}" }
        ) do
          raise "boom"
        end
      end

      assert_equal "boom", error.message
      assert_nil store.current_scope
      assert_same error, summary_input.fetch(:error)
      assert_equal :error, summary_input.fetch(:severity)
    end

    def test_context_store_with_execution_reports_finish_callback_failure
      store = Julewire::Core::ContextStore.current
      failures = []

      result = store.with_execution(
        type: :job,
        on_finish: ->(_scope) { raise "finish failed" },
        on_finish_failure: ->(error, phase:) { failures << [error.message, phase] }
      ) do
        :done
      end

      assert_equal :done, result
      assert_equal [["finish failed", :summary_emit]], failures
      assert_nil store.current_scope
    end

    def test_reset_clears_current_context
      Julewire.context.add(account_id: "acct-1")

      Julewire.reset!

      assert_nil Thread.current[context_store_thread_key]
      assert_empty Julewire.context.to_h
    end

    def test_reset_clears_cached_propagation_execution_snapshot
      store = Julewire::Core::ContextStore.current

      with_store_propagation(store, execution: { type: "request", id: "request-1" }) do
        assert_equal "request-1", store.current_scope_or_snapshot.execution_hash.fetch(:id)

        store.reset!

        assert_nil store.current_scope_or_snapshot
      end
    end

    def test_current_scope_or_snapshot_prefers_current_scope_over_propagation_snapshot
      store = Julewire::Core::ContextStore.current

      with_store_propagation(store, execution: { type: "request", id: "request-1" }) do
        store.with_execution(type: :job, id: "job-1", emit_summary: false) do
          assert_equal "job-1", store.current_scope_or_snapshot.execution_hash.fetch(:id)
        end
      end
    end

    def test_with_scope_pushes_view_and_restores_previous_scope
      store = Julewire::Core::ContextStore.new
      outer = build_execution_scope(type: :outer, id: "outer")
      inner = build_execution_scope(type: :inner, id: "inner")

      assert_false store.current_scope?

      result = store.with_scope(outer) do |outer_view|
        assert_true store.current_scope?
        assert_same outer, store.current_scope
        assert_instance_of Julewire::Core::Execution::View, outer_view
        refute_same outer, outer_view
        assert_equal "outer", outer_view.id

        inner_result = store.with_scope(inner) do |inner_view|
          assert_same inner, store.current_scope
          assert_instance_of Julewire::Core::Execution::View, inner_view
          refute_same inner, inner_view
          assert_equal "inner", inner_view.id
          :inner_result
        end

        assert_equal :inner_result, inner_result
        assert_same outer, store.current_scope
        :outer_result
      end

      assert_equal :outer_result, result
      assert_false store.current_scope?
      assert_nil store.current_scope
    end

    def test_scope_add_field_methods_copy_non_owned_input_by_default
      store = Julewire::Core::ContextStore.new
      scope = build_execution_scope(type: :worker, id: "worker-1")
      context = { "request" => { "id" => "original-context" } }
      carry = { "trace" => { "id" => "original-carry" } }
      attributes = { "web" => { "controller" => "OriginalController" } }

      store.with_scope(scope) do
        store.add_context(context)
        store.add_carry(carry)
        store.add_attributes(attributes)
        context.fetch("request")["id"] = "changed-context"
        carry.fetch("trace")["id"] = "changed-carry"
        attributes.fetch("web")["controller"] = "ChangedController"
      end

      assert_equal "original-context", scope.context_hash.dig(:request, :id)
      assert_equal "original-carry", scope.carry_hash.dig(:trace, :id)
      assert_equal "OriginalController", scope.attributes_hash.dig(:web, :controller)
    end

    def test_with_field_overlays_accept_keyword_only_input
      store = Julewire::Core::ContextStore.new

      store.with_context(request_id: "request-1") do
        store.with_carry(trace_id: "trace-1") do
          store.with_attributes(account_id: "acct-1") do
            store.with_neutral("worker.name": "Worker") do
              assert_equal({ request_id: "request-1" }, store.context_hash)
              assert_equal({ trace_id: "trace-1" }, store.carry_hash)
              assert_equal({ account_id: "acct-1" }, store.attributes_hash)
              assert_equal({ "worker.name": "Worker" }, store.neutral_hash)
            end
          end
        end
      end

      assert_empty store.context_hash
      assert_empty store.carry_hash
      assert_empty store.attributes_hash
      assert_empty store.neutral_hash
    end

    def test_with_field_overlays_default_to_unowned_user_input
      store = Julewire::Core::ContextStore.new
      metadata_field = { truncation_metadata_key => valid_truncation_metadata(fields: ["overlay"]) }

      %i[with_context with_carry with_attributes with_neutral].each do |method_name|
        reader = :"#{method_name.to_s.delete_prefix("with_")}_hash"

        error = assert_raises(ArgumentError, method_name.to_s) do
          store.public_send(method_name, metadata_field) { store.public_send(reader) }
        end

        assert_equal "_julewire_truncation is reserved for Julewire truncation metadata", error.message
      end
    end

    def test_owned_ambient_attribute_and_neutral_overlays_preserve_truncation_metadata
      store = Julewire::Core::ContextStore.new
      metadata_field = { truncation_metadata_key => owned_truncation_metadata(fields: ["overlay"]) }

      store.with_attributes(metadata_field, owned: true) do
        assert_equal ["overlay"], store.attributes_hash.dig(truncation_metadata_key.to_sym, :truncated_fields)
      end
      store.with_neutral(metadata_field, owned: true) do
        assert_equal ["overlay"], store.neutral_hash.dig(truncation_metadata_key.to_sym, :truncated_fields)
      end

      assert_empty store.attributes_hash
      assert_empty store.neutral_hash
    end

    def test_section_proxy_with_requires_block
      %i[context attributes].each do |proxy_name|
        error = assert_raises(ArgumentError, proxy_name.to_s) do
          Julewire.public_send(proxy_name).with(request_id: "request-1")
        end

        assert_equal "block required", error.message
      end
    end

    def test_scope_with_field_defaults_to_unowned_user_input
      scope = build_execution_scope(type: :worker, id: "worker-1")
      metadata_field = { truncation_metadata_key => valid_truncation_metadata(fields: ["overlay"]) }

      error = assert_raises(ArgumentError) do
        scope.with_field(:context, metadata_field) { scope.context_hash }
      end

      assert_equal "_julewire_truncation is reserved for Julewire truncation metadata", error.message
    end

    def test_scope_add_field_methods_preserve_owned_truncation_metadata
      store = Julewire::Core::ContextStore.new
      scope = build_execution_scope(type: :worker, id: "worker-1")
      key = Julewire::Core::Serialization::Serializer::TRUNCATION_METADATA_KEY.to_sym
      metadata = Julewire::Core::Serialization::Serializer.truncation_metadata(["field"], key_style: :symbol)

      store.with_scope(scope) do
        store.add_carry({ key => metadata }, owned: true)
        store.add_attributes({ key => metadata }, owned: true)
      end

      assert_equal ["field"], scope.carry_hash.dig(key, :truncated_fields)
      assert_equal ["field"], scope.attributes_hash.dig(key, :truncated_fields)
    end

    def test_delete_carry_inside_scope_does_not_delete_ambient_carry
      store = Julewire::Core::ContextStore.new
      scope = build_execution_scope(type: :worker, id: "worker-1", carry: { token: "scope" })
      store.add_carry(token: "ambient")

      store.with_scope(scope) do
        store.delete_carry(:token)

        assert_empty store.carry_hash
      end

      assert_equal({ token: "ambient" }, store.carry_hash)
    end

    def test_scope_with_context_yields_owned_overlay
      scope = build_execution_scope(type: :worker, id: "worker-1")
      key = Julewire::Core::Serialization::Serializer::TRUNCATION_METADATA_KEY.to_sym
      metadata = Julewire::Core::Serialization::Serializer.truncation_metadata(["field"], key_style: :symbol)
      inside = nil

      result = scope.with_context({ key => metadata }, owned: true) do
        inside = scope.context_hash
        :done
      end

      assert_equal :done, result
      assert_equal ["field"], inside.dig(key, :truncated_fields)
      assert_empty scope.context_hash
    end

    def test_scope_with_context_normalizes_public_string_keys_by_default
      scope = build_execution_scope(type: :worker, id: "worker-1")
      inside = nil

      scope.with_context({ "request" => { "id" => "request-1" } }) do
        inside = scope.context_hash
      end

      assert_equal({ request: { id: "request-1" } }, inside)
      assert_empty scope.context_hash
    end

    def test_with_scope_restores_scope_after_exception
      store = Julewire::Core::ContextStore.new
      scope = build_execution_scope(type: :job, id: "job-1")

      error = assert_raises(RuntimeError) do
        store.with_scope(scope) do |view|
          assert_instance_of Julewire::Core::Execution::View, view
          refute_same scope, view
          assert_equal "job-1", view.id
          raise "boom"
        end
      end

      assert_equal "boom", error.message
      assert_nil store.current_scope
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

      worker = safe_thread do
        Julewire.context.add(worker_id: "worker-1")
        ready << true
        resume_worker.pop
        worker_context << Julewire.context.to_h
      end

      assert safe_queue_pop(ready)
      Julewire.context.add(main: true)
      Julewire.reset!
      resume_worker << true

      assert_equal({ worker_id: "worker-1" }, safe_queue_pop(worker_context))

      assert_empty Julewire.context.to_h
    ensure
      resume_worker&.push(true)
      safe_thread_value(worker) if worker
    end

    def test_context_lookup_preserves_false_and_normalizes_string_ingress
      Julewire.context.add(enabled: false, empty: nil, "tenant_id" => "tenant-1")

      assert_false Julewire.context[:enabled]
      assert_false Julewire.context["enabled"]
      assert_nil Julewire.context[:empty]
      assert_equal "tenant-1", Julewire.context[:tenant_id]
      assert_equal "tenant-1", Julewire.context["tenant_id"]
      assert_nil Julewire.context[:missing]
      assert_nil Julewire.context["missing"]
      error = assert_raises(TypeError) { Julewire.context[Object.new] }
      assert_equal "field keys must be String or Symbol", error.message
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

    def test_direct_context_store_add_merges_keyword_fields_with_empty_inputs
      store = Julewire::Core::ContextStore.new

      store.add_context(nil, request_id: "request-1")

      assert_equal({ request_id: "request-1" }, store.context_hash)

      store.reset!
      store.add_context({}, request_id: "request-2")

      assert_equal({ request_id: "request-2" }, store.context_hash)
    end

    def test_direct_context_store_add_merges_keyword_fields_with_hash_inputs
      store = Julewire::Core::ContextStore.new
      fields = Class.new(Hash).new.merge!("account_id" => "acct-1")

      store.add_context(fields, request_id: "request-1")

      assert_equal({ account_id: "acct-1", request_id: "request-1" }, store.context_hash)
    end

    def test_direct_context_store_add_wraps_scalar_fields_with_keywords
      store = Julewire::Core::ContextStore.new

      store.add_context("request-context", request_id: "request-1")

      assert_equal({ value: "request-context", request_id: "request-1" }, store.context_hash)
    end

    def test_direct_context_store_add_treats_default_fields_as_user_input
      store = Julewire::Core::ContextStore.new

      error = assert_raises(ArgumentError) do
        store.add_context(truncation_metadata_key => valid_truncation_metadata(fields: ["ids"]))
      end

      assert_equal "_julewire_truncation is reserved for Julewire truncation metadata", error.message
    end

    def test_direct_context_store_owned_add_preserves_ambient_truncation_metadata
      store = Julewire::Core::ContextStore.new

      store.add_context({ truncation_metadata_key => owned_truncation_metadata(fields: ["ids"]) }, owned: true)

      assert_symbol_truncation_metadata store.context_hash.fetch(truncation_metadata_key),
                                        fields: ["ids"],
                                        max_depth: 20,
                                        max_string_bytes: 10
    end

    def test_direct_context_store_owned_add_preserves_scoped_truncation_metadata
      store = Julewire::Core::ContextStore.new

      store.with_execution(type: :job, emit_summary: false) do
        store.add_context({ truncation_metadata_key => owned_truncation_metadata(fields: ["ids"]) }, owned: true)

        assert_symbol_truncation_metadata store.context_hash.fetch(truncation_metadata_key),
                                          fields: ["ids"],
                                          max_depth: 20,
                                          max_string_bytes: 10
      end
    end

    def test_direct_context_store_add_neutral_default_is_noop
      store = Julewire::Core::ContextStore.new

      assert_nil store.add_neutral

      assert_empty store.neutral_hash
    end

    def test_direct_context_store_scoped_add_neutral_treats_default_as_user_input
      store = Julewire::Core::ContextStore.new

      store.with_execution(type: :job, emit_summary: false) do
        error = assert_raises(ArgumentError) do
          store.add_neutral(truncation_metadata_key => valid_truncation_metadata(fields: ["neutral"]))
        end

        assert_equal "_julewire_truncation is reserved for Julewire truncation metadata", error.message
      end
    end

    def test_direct_context_store_scoped_add_neutral_positional_hash_treats_default_as_user_input
      store = Julewire::Core::ContextStore.new
      metadata_field = { truncation_metadata_key => valid_truncation_metadata(fields: ["neutral"]) }

      store.with_execution(type: :job, emit_summary: false) do
        error = assert_raises(ArgumentError) { store.add_neutral(metadata_field) }

        assert_equal "_julewire_truncation is reserved for Julewire truncation metadata", error.message
      end
    end

    def test_direct_context_store_scoped_owned_add_neutral_preserves_truncation_metadata
      store = Julewire::Core::ContextStore.new

      store.with_execution(type: :job, emit_summary: false) do
        store.add_neutral({ truncation_metadata_key => owned_truncation_metadata(fields: ["neutral"]) }, owned: true)

        assert_symbol_truncation_metadata store.current_scope.neutral_hash.fetch(truncation_metadata_key),
                                          fields: ["neutral"],
                                          max_depth: 20,
                                          max_string_bytes: 10
      end
    end

    def test_direct_context_store_field_values_forward_defaults
      store = Julewire::Core::ContextStore.new

      assert_equal :fallback, store.context_value(:missing, default: :fallback)
      assert_equal :fallback, store.carry_value(:missing, default: :fallback)
      assert_equal :fallback, store.attributes_value(:missing, default: :fallback)

      store.add_context(enabled: false)
      store.add_carry(enabled: false)
      store.add_attributes(enabled: false)

      assert_false store.context_value(:enabled, default: :fallback)
      assert_false store.carry_value(:enabled, default: :fallback)
      assert_false store.attributes_value(:enabled, default: :fallback)
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

    def test_section_proxy_mutators_return_proxy_for_chaining
      assert_same Julewire.context, Julewire.context.add(request_id: "request-1")
      assert_same Julewire.attributes, Julewire.attributes.add(tenant_id: "tenant-1")
      assert_same Julewire.carry, Julewire.carry.add(trace: { id: "trace-1" })
      assert_same Julewire.carry, Julewire.carry.delete(:trace)
    end

    def test_carry_lookup_handles_no_delete_and_top_level_delete
      Julewire.carry.add(trace: { id: "trace-1" })

      assert_equal({ id: "trace-1" }, Julewire.carry[:trace])

      Julewire.carry.delete(:trace)

      assert_nil Julewire.carry[:trace]
    end

    def test_direct_context_store_delete_carry_normalizes_string_path_for_lookup
      store = Julewire::Core::ContextStore.new
      store.add_carry(trace: { id: "trace-1", kept: true })

      store.delete_carry("trace")

      assert_nil store.carry_value(:trace, default: nil)
    end

    def test_scope_delete_carry_treats_nil_path_as_noop
      scope = build_execution_scope(type: :worker, id: "worker-1", carry: { trace: { id: "trace-1" } })

      scope.delete_carry(nil)

      assert_equal({ trace: { id: "trace-1" } }, scope.carry_hash)
    end

    def test_ambient_carry_without_normalizes_path_and_restores_after_block
      Julewire.carry.add(http: { request_headers: { traceparent: "trace", authorization: "secret" } })

      inside = Julewire.carry.without("http", "request_headers", "authorization") do
        Julewire.carry.to_h
      end

      assert_equal({ http: { request_headers: { traceparent: "trace" } } }, inside)
      assert_equal "secret", Julewire.carry[:http].dig(:request_headers, :authorization)
    end

    def test_context_store_carry_without_normalizes_nested_string_path
      Julewire.carry.add(http: { request_headers: { traceparent: "trace", authorization: "secret" } })

      inside = Julewire::Core::ContextStore.current.without_carry([%w[http request_headers], "authorization"]) do
        Julewire.carry.to_h
      end

      assert_equal({ http: { request_headers: { traceparent: "trace" } } }, inside)
      assert_equal "secret", Julewire.carry[:http].dig(:request_headers, :authorization)
    end

    def test_scope_carry_without_masks_only_inside_block
      inside = nil
      after = nil

      with_julewire_job do
        Julewire.carry.add(http: { request_headers: { traceparent: "trace", authorization: "secret" } })

        Julewire.carry.without(:http, :request_headers, :authorization) do
          inside = Julewire.carry.to_h
        end
        after = Julewire.carry.to_h
      end

      assert_equal({ http: { request_headers: { traceparent: "trace" } } }, inside)
      assert_equal({ http: { request_headers: { traceparent: "trace", authorization: "secret" } } }, after)
    end

    def test_carry_without_rejects_empty_path
      error = assert_raises(ArgumentError) do
        Julewire.carry.without { :unused }
      end

      assert_equal "carry path is required", error.message

      nested_error = assert_raises(ArgumentError) do
        Julewire.carry.without([]) { :unused }
      end

      assert_equal "carry path is required", nested_error.message
    end

    def test_carry_without_requires_block
      error = assert_raises(ArgumentError) do
        Julewire.carry.without(:http)
      end

      assert_equal "block required", error.message
    end

    def test_ambient_context_overlay_defensively_copies_caller_hashes
      assert_context_overlay_defensively_copies_caller_hashes do |fields, capture|
        Julewire.context.with(fields) { capture.call }
      end
    end

    def test_ambient_user_overlay_wraps_scalar_fields
      Julewire.context.with("request-context") do
        assert_equal({ value: "request-context" }, Julewire.context.to_h)
      end
    end

    def test_ambient_owned_overlay_rejects_scalar_fields
      store = Julewire::Core::ContextStore.current

      error = assert_raises(TypeError) do
        store.with_context("request-context", owned: true) { flunk "invalid owned input yielded" }
      end

      assert_equal "owned data must be a Hash", error.message
      assert_empty Julewire.context.to_h
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

      with_store_propagation(store, context: { outer: true }, execution: { trace_id: "trace-1" }) do
        assert_raises(RuntimeError) do
          with_store_propagation(store, context: BrokenHash[bad: true], execution: { span_id: "span-1" }) { :unused }
        end

        assert_equal({ outer: true }, store.context_hash)
        assert_equal "trace-1", store.current_scope_or_snapshot.execution_hash[:trace_id]
      end
    end

    def test_propagation_snapshot_reuses_effective_execution_until_overlay_changes
      store = Julewire::Core::ContextStore.current

      with_store_propagation(store, execution: { trace_id: "trace-1", root: { type: "request", id: "req-1" } }) do
        first = store.current_scope_or_snapshot.execution_hash
        second = store.current_scope_or_snapshot.execution_hash

        assert_equal first, second
        assert_equal "trace-1", second[:trace_id]
        assert_equal "request", second.dig(:root, :type)

        with_store_propagation(store, execution: { span_id: "span-1" }) do
          nested = store.current_scope_or_snapshot.execution_hash

          assert_equal "trace-1", nested[:trace_id]
          assert_equal "span-1", nested[:span_id]
        end

        assert_equal second, store.current_scope_or_snapshot.execution_hash
      end
    end

    def test_owned_propagation_preserves_truncation_metadata
      store = Julewire::Core::ContextStore.current
      truncation_key = truncation_metadata_key
      metadata = owned_truncation_metadata(fields: ["trace"])

      with_store_propagation(
        store,
        execution: { trace_id: "trace-1", root: { type: "request" }, truncation_key => metadata },
        owned: true
      ) do
        execution = store.current_scope_or_snapshot.execution_hash

        assert_equal "trace-1", execution.fetch(:trace_id)
        assert_equal "request", execution.dig(:root, :type)
        assert_symbol_truncation_metadata execution.fetch(truncation_key),
                                          fields: ["trace"],
                                          max_depth: 20,
                                          max_string_bytes: 10
      end

      store.with_execution(type: :job, id: "job-after", emit_summary: false) do |execution|
        refute_includes execution.execution_hash, :trace_id
      end
    end

    def test_owned_propagation_truncation_metadata_survives_nested_execution_inheritance
      store = Julewire::Core::ContextStore.current
      truncation_key = truncation_metadata_key
      metadata = owned_truncation_metadata(fields: ["trace"])

      with_store_propagation(store, execution: { truncation_key => metadata }, owned: true) do
        store.with_execution(type: :parent, emit_summary: false) do
          store.with_execution(type: :child, emit_summary: false) do |execution|
            assert_symbol_truncation_metadata execution.execution_hash.fetch(truncation_key),
                                              fields: ["trace"],
                                              max_depth: 20,
                                              max_string_bytes: 10
          end
        end
      end
    end

    def test_owned_propagation_execution_cache_detaches_from_mutable_input
      store = Julewire::Core::ContextStore.current
      execution = { trace: { id: "trace-1" } }

      with_store_propagation(store, execution: execution, owned: true) do
        cache = store.__send__(:propagation_execution_hash)

        assert_equal({ trace: { id: "trace-1" } }, cache)
        assert_predicate cache, :frozen?
        assert_predicate cache.fetch(:trace), :frozen?

        store.with_execution(type: :first, emit_summary: false) do |scope|
          assert_equal "trace-1", scope.execution_hash.dig(:trace, :id)
        end

        execution.fetch(:trace)[:id] = "changed"

        store.with_execution(type: :second, emit_summary: false) do |scope|
          assert_equal "trace-1", scope.execution_hash.dig(:trace, :id)
        end
      end
    end

    def test_unowned_propagation_rejects_reserved_truncation_metadata
      store = Julewire::Core::ContextStore.current

      error = assert_raises(ArgumentError) do
        with_store_propagation(
          store,
          execution: { truncation_metadata_key => valid_truncation_metadata(fields: ["trace"]) }
        ) { :unused }
      end

      assert_equal "_julewire_truncation is reserved for Julewire truncation metadata", error.message
    end

    def test_scoped_owned_propagation_applies_carry_and_context_temporarily
      store = Julewire::Core::ContextStore.current
      metadata = owned_truncation_metadata(fields: ["headers"])
      metadata_field = { truncation_metadata_key => metadata }

      with_julewire_job do
        Julewire.context.add(tenant_id: "tenant-1")
        Julewire.carry.add(trace: "outer")

        with_store_propagation(
          store,
          context: { request_id: "request-1", metadata: metadata_field },
          carry: { trace: "inner", metadata: metadata_field },
          owned: true
        ) do
          assert_equal "request-1", Julewire.context[:request_id]
          assert_equal "inner", Julewire.carry[:trace]
          assert_symbol_truncation_metadata Julewire.context.to_h.dig(:metadata, truncation_metadata_key),
                                            fields: ["headers"],
                                            max_depth: 20,
                                            max_string_bytes: 10
          assert_symbol_truncation_metadata Julewire.carry.to_h.dig(:metadata, truncation_metadata_key),
                                            fields: ["headers"],
                                            max_depth: 20,
                                            max_string_bytes: 10
        end

        assert_equal "tenant-1", Julewire.context[:tenant_id]
        assert_nil Julewire.context[:request_id]
        assert_equal "outer", Julewire.carry[:trace]
      end
    end

    def test_owned_execution_options_preserve_attributes_and_neutral_truncation_metadata
      store = Julewire::Core::ContextStore.current

      store.with_execution(
        type: :job,
        emit_summary: false,
        owned: true,
        attributes: owned_execution_attributes,
        neutral: owned_execution_neutral
      ) do
        scope = store.current_scope

        assert_owned_execution_metadata(scope)
      end
    end

    def test_public_owned_execution_options_preserve_attributes_and_neutral_truncation_metadata
      Julewire.with_execution(
        type: :job,
        emit_summary: false,
        owned: true,
        attributes: owned_execution_attributes,
        neutral: owned_execution_neutral
      ) do
        execution = Julewire::Core::ContextStore.current.current_scope

        assert_owned_execution_metadata(execution)
      end
    end

    def test_nested_executions_inherit_attributes_by_default
      store = Julewire::Core::ContextStore.new

      store.with_execution(type: :outer, attributes: { account_id: "acct-1" }) do
        store.with_execution(type: :inner) do
          assert_equal "acct-1", store.current_scope.attributes_hash.fetch(:account_id)
        end
      end
    end

    def test_unowned_execution_options_reject_reserved_attribute_and_neutral_keys
      store = Julewire::Core::ContextStore.current
      metadata_field = { truncation_metadata_key => valid_truncation_metadata(fields: ["execution"]) }

      %i[attributes neutral].each do |section|
        error = assert_raises(ArgumentError, section.to_s) do
          store.with_execution(type: :job, emit_summary: false, **{ section => metadata_field }) do
            store.current_scope.public_send(:"#{section}_hash")
          end
        end

        assert_equal "_julewire_truncation is reserved for Julewire truncation metadata", error.message
      end
    end

    def test_public_unowned_execution_options_reject_reserved_attribute_and_neutral_keys
      metadata_field = { truncation_metadata_key => valid_truncation_metadata(fields: ["execution"]) }

      %i[attributes neutral].each do |section|
        error = assert_raises(ArgumentError, section.to_s) do
          Julewire.with_execution(type: :job, emit_summary: false, **{ section => metadata_field }) do
            Julewire::Core::ContextStore.current.current_scope.public_send(:"#{section}_hash")
          end
        end

        assert_equal "_julewire_truncation is reserved for Julewire truncation metadata", error.message
      end
    end

    def test_context_only_propagation_does_not_create_execution_snapshot
      store = Julewire::Core::ContextStore.current
      records = capture_julewire_records do
        Julewire::Core::Propagation.restore({ context: { request_id: "req-1" } }) do
          assert_nil store.current_scope_or_snapshot
          Julewire.emit(message: "inside")
        end
      end

      record = records.fetch(0)

      assert_equal({ request_id: "req-1" }, record.fetch(:context))
      assert_empty record.fetch(:execution)
    end

    def test_linked_propagation_snapshot_still_parents_new_executions
      store = Julewire::Core::ContextStore.current

      with_store_propagation(store, execution: { type: "request", id: "request-1" }, link_executions: true) do
        store.with_execution(type: :job, id: "job-1") do |execution|
          assert_equal 2, execution.execution_hash[:depth]
          assert_equal "request-1", execution.execution_hash.dig(:parent, :id)
        end
      end

      store.with_execution(type: :job, id: "job-2") do |execution|
        assert_nil execution.execution_hash[:parent]
      end
    end

    def test_unlinked_propagation_snapshot_does_not_parent_new_executions
      store = Julewire::Core::ContextStore.current

      with_store_propagation(store, execution: { type: "request", id: "request-1" }, link_executions: false) do
        store.with_execution(type: :job, id: "job-1") do |execution|
          assert_equal 1, execution.execution_hash.fetch(:depth)
          refute_includes execution.execution_hash, :parent
        end
      end
    end

    def test_nested_unlinked_propagation_with_execution_hides_outer_linked_parent
      store = Julewire::Core::ContextStore.current

      with_store_propagation(store, execution: { type: "request", id: "request-1" }, link_executions: true) do
        with_store_propagation(store, execution: { type: "message", id: "message-1" }, link_executions: false) do
          store.with_execution(type: :job, id: "job-1") do |execution|
            assert_equal "job-1", execution.execution_hash.fetch(:id)
            refute_includes execution.execution_hash, :parent
          end
        end
      end
    end

    def test_propagation_execution_merges_into_nested_current_scope
      store = Julewire::Core::ContextStore.current

      store.with_execution(type: :outer, id: "outer-1") do
        with_store_propagation(store, execution: { trace_id: "trace-1" }) do
          store.with_execution(type: :inner, id: "inner-1") do |execution|
            assert_equal "inner-1", execution.execution_hash.fetch(:id)
            assert_equal "trace-1", execution.execution_hash.fetch(:trace_id)
          end
        end
      end
    end

    def test_linked_propagation_snapshot_is_refreshed_between_restores
      store = Julewire::Core::ContextStore.current

      with_store_propagation(store, execution: { type: "request", id: "request-1" }, link_executions: true) do
        store.with_execution(type: :job, id: "job-1") { :unused }
      end

      with_store_propagation(store, execution: { type: "request", id: "request-2" }, link_executions: true) do
        store.with_execution(type: :job, id: "job-2") do |execution|
          assert_equal "request-2", execution.execution_hash.dig(:parent, :id)
        end
      end
    end

    def test_linked_propagation_uses_restored_lineage_depth
      store = Julewire::Core::ContextStore.current

      with_store_propagation(
        store,
        execution: {
          type: "consumer",
          id: "consumer-1",
          depth: 9,
          root: { type: "request", id: "request-1" },
          parent: { type: "job", id: "job-1" }
        },
        link_executions: true
      ) do
        store.with_execution(type: :handler, id: "handler-1") do |execution|
          execution_hash = execution.execution_hash

          assert_equal 10, execution_hash.fetch(:depth)
          assert_equal({ type: "request", id: "request-1" }, execution_hash.fetch(:root))
          assert_equal({ type: "consumer", id: "consumer-1" }, execution_hash.fetch(:parent))
        end
      end
    end

    def test_empty_nested_propagation_does_not_hide_outer_linked_lineage
      store = Julewire::Core::ContextStore.current

      with_store_propagation(store, execution: { type: "request", id: "request-1" }, link_executions: true) do
        with_store_propagation(store, execution: {}) do
          store.with_execution(type: :job, id: "job-1") do |execution|
            assert_equal "request-1", execution.execution_hash.dig(:parent, :id)
          end
        end
      end
    end

    def test_linked_owned_propagation_snapshot_preserves_truncation_metadata
      store = Julewire::Core::ContextStore.current
      truncation_key = truncation_metadata_key
      metadata = owned_truncation_metadata(fields: ["trace"])

      with_store_propagation(
        store,
        execution: {
          type: "request",
          id: "request-1",
          truncation_key => metadata
        },
        link_executions: true,
        owned: true
      ) do
        store.with_execution(type: :job, id: "job-1") do |execution|
          parent_execution = execution.parent.execution_hash

          assert_symbol_truncation_metadata parent_execution.fetch(truncation_key),
                                            fields: ["trace"],
                                            max_depth: 20,
                                            max_string_bytes: 10
        end
      end
    end

    private

    def with_store_propagation(store, context: {}, carry: {}, execution: {}, link_executions: false, owned: false, &)
      store.with_propagation(context: context, carry: carry, execution: execution, link_executions: link_executions,
                             owned: owned, &)
    end

    def truncation_metadata_key
      Julewire::Core::Serialization::Serializer::TRUNCATION_METADATA_KEY.to_sym
    end

    def valid_truncation_metadata(fields:)
      {
        "truncated" => true,
        "truncated_fields" => fields,
        "limits" => {
          "max_array_items" => nil,
          "max_depth" => 20,
          "max_hash_keys" => nil,
          "max_string_bytes" => 10
        }
      }
    end

    def owned_truncation_metadata(fields:)
      {
        truncated: true,
        truncated_fields: fields,
        limits: {
          max_array_items: nil,
          max_depth: 20,
          max_hash_keys: nil,
          max_string_bytes: 10
        }
      }
    end

    def owned_execution_attributes
      { app: { version: "1" } }.merge(owned_execution_metadata_field)
    end

    def owned_execution_neutral
      { http: { method: "GET" } }.merge(owned_execution_metadata_field)
    end

    def owned_execution_metadata_field
      { truncation_metadata_key => owned_truncation_metadata(fields: ["execution"]) }
    end

    def assert_owned_execution_metadata(scope)
      assert_equal "1", scope.attributes_hash.dig(:app, :version)
      assert_equal "GET", scope.neutral_hash.dig(:http, :method)
      assert_symbol_truncation_metadata scope.attributes_hash.fetch(truncation_metadata_key),
                                        fields: ["execution"],
                                        max_depth: 20,
                                        max_string_bytes: 10
      assert_symbol_truncation_metadata scope.neutral_hash.fetch(truncation_metadata_key),
                                        fields: ["execution"],
                                        max_depth: 20,
                                        max_string_bytes: 10
    end

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
