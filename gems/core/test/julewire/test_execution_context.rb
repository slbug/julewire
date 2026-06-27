# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestExecutionContext < Minitest::Test
    cover "Julewire::Core::ContextStore#merged_execution_hash"
    cover Julewire::Core::Execution::Scope
    cover "Julewire::Core::FacadeMethods#context"
    cover "Julewire::Core::FacadeMethods#current_execution"
    cover "Julewire::Core::FacadeMethods#current_execution?"
    cover "Julewire::Core::FacadeMethods#start_execution"
    cover "Julewire::Core::FacadeMethods#with_execution"
    cover "Julewire::Core::Runtime#current_execution"
    cover "Julewire::Core::Runtime#start_execution"
    cover "Julewire::Core::Runtime#with_execution"
    cover "Julewire::Core::Execution::Boundary#open_context_execution"
    cover "Julewire::Core::Execution::Boundary#start_execution"
    cover "Julewire::Core::Execution::Boundary#with_execution"
    cover "Julewire::Core::ContextStore#start_execution"
    cover "Julewire::Core::ContextStore#build_scope"
    cover "Julewire::Core::ContextStore#with_execution"

    def test_with_execution_preserves_explicit_id
      scope = Julewire.with_execution(type: :worker, id: "scope-1", emit_summary: false) do |execution|
        execution
      end

      assert_equal "scope-1", scope.id
      assert_equal "scope-1", scope.execution_hash[:id]
    end

    def test_with_execution_requires_block
      error = assert_raises(ArgumentError) { Julewire.with_execution(type: :worker, emit_summary: false) }

      assert_equal "block required", error.message
    end

    def test_nested_execution_scope_tracks_parent_and_restores_current_scope
      outer_scope = nil
      inner_scope = nil
      current_after_inner = nil

      Julewire.with_execution(type: :outer, id: "outer", emit_summary: false) do |outer|
        outer_scope = outer
        Julewire.context.add(level: "outer")

        Julewire.with_execution(type: :inner, id: "inner", emit_summary: false) do |inner|
          inner_scope = inner

          assert_equal outer_scope.id, inner.parent.id
          assert_equal "outer", Julewire.context.to_h[:level]
        end

        current_after_inner = Julewire.current_execution
      end

      assert_equal outer_scope.id, current_after_inner.id
      refute_respond_to current_after_inner, :add_context
      refute_respond_to current_after_inner, :add_summary
      refute_respond_to current_after_inner, :finish
      refute_respond_to inner_scope, :finish
      assert_nil Julewire.current_execution
    end

    def test_nested_execution_scope_restores_current_scope_after_exception
      current_after_inner = nil

      error = assert_raises(RuntimeError) do
        Julewire.with_execution(type: :outer, id: "outer", emit_summary: false) do
          Julewire.with_execution(type: :inner, id: "inner", emit_summary: false) do
            raise "boom"
          end
        ensure
          current_after_inner = Julewire.current_execution
        end
      end

      assert_equal "boom", error.message
      assert_equal "outer", current_after_inner.id
      assert_nil Julewire.current_execution
    end

    def test_nested_execution_scope_inherits_parent_execution_fields
      inner_execution = nil
      inner_depth = nil

      Julewire.with_execution(type: :outer, id: "outer", fields: { trace_id: "trace-1" }, emit_summary: false) do
        Julewire.with_execution(type: :inner, id: "inner", emit_summary: false) do
          inner_execution = Julewire.current_execution.execution_hash
          inner_depth = Julewire::Core::ContextStore.current.current_scope.depth
        end
      end

      assert_equal "trace-1", inner_execution[:trace_id]
      assert_equal "inner", inner_execution[:id]
      assert_equal "inner", inner_execution[:type]
      assert_equal 2, inner_depth
    end

    def test_execution_scope_treats_nil_section_options_as_empty_hashes
      view = Julewire.with_execution(
        type: :job,
        fields: nil,
        attributes: nil,
        neutral: nil,
        labels: nil,
        emit_summary: false
      ) do |execution|
        execution
      end

      assert_equal view.id, view.execution_hash.fetch(:id)
      assert_equal "job", view.execution_hash.fetch(:type)
      refute_includes view.execution_hash, :fields
      assert_empty view.attributes_hash
      assert_empty view.neutral_hash
      assert_empty view.labels_hash
    end

    def test_execution_scope_internal_defaults_are_empty_and_unfinished
      scope = Julewire::Core::Execution::Scope.new(type: :job)

      assert_empty scope.carry_hash
      assert_empty scope.neutral_hash
      assert_empty scope.frozen_labels_hash
      assert_equal({}, scope.labels_hash)
      refute_predicate scope, :finished?
    end

    def test_execution_scope_child_owns_frozen_parent_reference
      parent = Julewire::Core::Execution::Scope.new(type: :job, id: "job-1")
      child = Julewire::Core::Execution::Scope.new(type: :task, id: "task-1", parent: parent)

      reference = child.lineage.parent_reference

      assert_equal({ type: "job", id: "job-1" }, reference)
      assert_predicate reference, :frozen?
      refute_same parent.lineage.root_reference, reference
    end

    def test_execution_scope_non_standard_exception_reflects_recorded_summary_errors
      scope = Julewire::Core::Execution::Scope.new(type: :job)

      refute_predicate scope, :non_standard_exception?

      scope.record_error(SystemStackError.new("stack"))

      assert_predicate scope, :non_standard_exception?
    end

    def test_execution_scope_labels_hash_is_a_deep_copy
      labels = { app: { name: "api" } }
      view = Julewire.with_execution(type: :job, labels: labels, emit_summary: false) { it }

      copied = view.labels_hash
      copied[:app][:name] = "mutated"

      assert_equal "api", view.labels_hash.dig(:app, :name)
    end

    def test_with_execution_forwards_all_public_scope_options
      view = nil
      execution = nil
      attributes = nil
      neutral = nil
      labels = nil

      Julewire.attributes.add(inherited: true)
      Julewire.with_execution(
        type: :job,
        id: "job-1",
        fields: { trace_id: "trace-1" },
        attributes: { job: { id: "job-1" } },
        neutral: { transport: { system: "test" } },
        labels: { service: "worker" },
        owned: false,
        inherit_attributes: false,
        emit_summary: false
      ) do |current|
        view = current
        execution = current.execution_hash
        attributes = current.attributes_hash
        neutral = current.neutral_hash
        labels = current.labels_hash
      end

      assert_equal "job-1", view.id
      assert_equal "trace-1", execution.fetch(:trace_id)
      assert_equal({ id: "job-1" }, attributes.fetch(:job))
      refute_includes attributes, :inherited
      assert_equal({ system: "test" }, neutral.fetch(:transport))
      assert_equal "worker", labels.fetch(:service)
    end

    def test_with_execution_forwards_owned_scope_options
      attributes = { owned: { value: 1 } }
      neutral = { owned: { value: 2 } }
      view = nil

      Julewire.with_execution(
        type: :job,
        attributes: attributes,
        neutral: neutral,
        owned: true,
        emit_summary: false
      ) do |execution|
        view = execution

        assert_equal({ value: 1 }, execution.attributes_hash.fetch(:owned))
        assert_equal({ value: 2 }, execution.neutral_hash.fetch(:owned))
      end

      attributes.fetch(:owned)[:value] = 3
      neutral.fetch(:owned)[:value] = 4

      assert_equal 1, view.attributes_hash.dig(:owned, :value)
      assert_equal 2, view.neutral_hash.dig(:owned, :value)
    end

    def test_with_execution_copies_scope_options_by_default
      attributes = { job: { ids: ["one"] } }
      neutral = { transport: { ids: ["one"] } }
      view = Julewire.with_execution(
        type: :job,
        attributes: attributes,
        neutral: neutral,
        emit_summary: false
      ) { it }

      attributes.dig(:job, :ids) << "two"
      neutral.dig(:transport, :ids) << "two"

      assert_equal ["one"], view.attributes_hash.dig(:job, :ids)
      assert_equal ["one"], view.neutral_hash.dig(:transport, :ids)
    end

    def test_start_execution_forwards_public_scope_options
      Julewire.attributes.add(inherited: true)
      handle = Julewire.start_execution(
        type: :job,
        id: "job-1",
        fields: { trace_id: "trace-1" },
        attributes: { job: { id: "job-1" } },
        neutral: { transport: { system: "test" } },
        labels: { service: "worker" },
        inherit_attributes: false,
        emit_summary: false
      )
      view = handle.snapshot

      assert_equal "job-1", view.id
      assert_equal "trace-1", view.execution_hash.fetch(:trace_id)
      assert_equal({ id: "job-1" }, view.attributes_hash.fetch(:job))
      refute_includes view.attributes_hash, :inherited
      assert_equal({ system: "test" }, view.neutral_hash.fetch(:transport))
      assert_equal "worker", view.labels_hash.fetch(:service)
    ensure
      handle&.finish
    end

    def test_context_store_start_execution_allows_missing_callbacks
      handle = Julewire::Core::ContextStore.current.start_execution(type: :job)

      assert_equal "job", handle.snapshot.type
      assert_true handle.finish
    end

    def test_context_store_start_execution_invokes_finish_callback
      finished = []
      handle = Julewire::Core::ContextStore.current.start_execution(
        type: :job,
        id: "job-1",
        on_finish: ->(scope) { finished << scope.id },
        on_finish_failure: ->(_error, phase:) { flunk "unexpected #{phase}" }
      )

      assert_true handle.finish
      assert_equal ["job-1"], finished
    end

    def test_context_store_start_execution_reports_finish_callback_failures
      failures = []
      handle = Julewire::Core::ContextStore.current.start_execution(
        type: :job,
        on_finish: ->(_scope) { raise "finish failed" },
        on_finish_failure: ->(error, phase:) { failures << [error.message, phase] }
      )

      assert_true handle.finish
      assert_equal [["finish failed", :summary_emit]], failures
    end

    def test_context_store_start_execution_normalizes_unowned_execution_by_default
      handle = Julewire::Core::ContextStore.current.start_execution(
        type: :job,
        execution: { "trace" => { "span_id" => "span-1" } }
      )

      assert_equal "span-1", handle.snapshot.execution_hash.dig(:trace, :span_id)
      assert_true handle.finish
    end

    def test_execution_fields_accept_hash_subclasses
      fields = Class.new(Hash).new.merge!("trace_id" => "trace-1")
      execution = nil

      Julewire.with_execution(type: :request, fields: fields, emit_summary: false) do
        execution = Julewire.current_execution.execution_hash
      end

      assert_equal "trace-1", execution.fetch(:trace_id)
    end

    def test_execution_fields_do_not_squat_control_keywords
      execution = nil
      attributes = nil

      Julewire.with_execution(
        type: :operation,
        fields: { attributes: "execution-field", summary_event: "execution.summary" },
        attributes: { actual: true },
        emit_summary: false
      ) do
        execution = Julewire.current_execution.execution_hash
        attributes = Julewire.attributes.to_h
      end

      assert_equal "execution-field", execution[:attributes]
      assert_equal "execution.summary", execution[:summary_event]
      assert_equal({ actual: true }, attributes)
    end

    def test_execution_fields_are_copied_before_scope_owns_them
      fields = {
        "trace_id" => "trace-1",
        "root" => { "type" => "spoofed", "id" => "root" },
        "custom" => { "ids" => ["one"] }
      }
      original = Marshal.load(Marshal.dump(fields))
      execution = nil

      Julewire.with_execution(type: :request, id: "request-1", fields: fields, emit_summary: false) do
        execution = Julewire.current_execution.execution_hash
      end

      assert_equal original, fields
      assert_equal "trace-1", execution[:trace_id]
      assert_equal ["one"], execution.dig(:custom, :ids)
      assert_equal({ type: "request", id: "request-1" }, execution[:root])
      refute_includes execution, "root"

      fields.fetch("custom").fetch("ids") << "two"

      assert_equal ["one"], execution.dig(:custom, :ids)
    end

    def test_nested_execution_scope_can_skip_inherited_attributes
      inherited_attributes = nil
      isolated_attributes = nil
      inherited_attribute_value = nil
      missing_attribute_value = :unset

      Julewire.with_execution(type: :outer, id: "outer", emit_summary: false) do
        Julewire.attributes.add("my_app.request_method": "GET", app: { request: true })

        Julewire.with_execution(type: :inherited, emit_summary: false) do
          inherited_attributes = Julewire.current_execution.attributes_hash
          inherited_attribute_value = Julewire.attributes[:"my_app.request_method"]
          missing_attribute_value = Julewire.attributes[:missing]
        end

        Julewire.with_execution(
          type: :isolated,
          emit_summary: false,
          inherit_attributes: false,
          attributes: { job: { id: "job-1" } }
        ) do
          isolated_attributes = Julewire.current_execution.attributes_hash
        end
      end

      assert_equal "GET", inherited_attributes[:"my_app.request_method"]
      assert_equal "GET", inherited_attribute_value
      assert_nil missing_attribute_value
      assert_equal({ request: true }, inherited_attributes[:app])
      refute_includes isolated_attributes, :"my_app.request_method"
      refute_includes isolated_attributes, :app
      assert_equal({ id: "job-1" }, isolated_attributes[:job])
    end

    def test_child_scope_captures_parent_fields_at_creation
      child_context = nil
      child_attributes = nil
      child_carry = nil

      Julewire.with_execution(type: :outer, emit_summary: false) do
        Julewire.context.add(account: { plan: "free" })
        Julewire.attributes.add(app: { version: "one" })
        Julewire.carry.add(http: { request_headers: { traceparent: "trace-1", authorization: "secret" } })

        Julewire.with_execution(type: :child, emit_summary: false) do
          child_context = Julewire.current_execution.context_hash
          child_attributes = Julewire.current_execution.attributes_hash
          child_carry = Julewire.current_execution.carry_hash
        end

        Julewire.context.add(account: { plan: "pro" }, late_context: true)
        Julewire.attributes.add(app: { version: "two" }, late_attribute: true)
        Julewire.carry.delete(:http, :request_headers, :authorization)
      end

      assert_equal({ plan: "free" }, child_context.fetch(:account))
      refute_includes child_context, :late_context
      assert_equal({ version: "one" }, child_attributes.fetch(:app))
      refute_includes child_attributes, :late_attribute
      assert_equal "secret", child_carry.dig(:http, :request_headers, :authorization)
    end

    def test_execution_scope_duration_uses_monotonic_time
      metrics = nil
      with_monotonic_times(10.0, 10.25) do
        Julewire::Core::ContextStore.current.with_execution(
          type: :job,
          started_at: Time.utc(2026, 1, 1),
          on_finish: ->(scope) { metrics = scope.summary_record_input.fetch(:metrics) }
        ) do |execution|
          assert_equal "job", execution.type
          assert_equal Time.utc(2026, 1, 1), execution.started_at
        end
      end

      assert_equal 250, metrics.fetch(:duration_ms)
    end

    def test_finish_callback_errors_are_swallowed
      result = Julewire::Core::ContextStore.current.with_execution(
        type: :job,
        on_finish: ->(_scope) { raise "finish failed" }
      ) do
        :ok
      end

      assert_equal :ok, result
      assert_nil Julewire.current_execution
    end

    def test_summary_fields_defensively_copy_caller_hashes
      fields = { result: { count: 1 } }
      appended = { code: "slow" }
      scope = nil

      with_julewire_job do
        Julewire.summary.add(fields)
        Julewire.summary.append(:warnings, appended)
        scope = Julewire.current_execution
        fields[:result][:count] = 2
        appended[:code] = "changed"
      end

      assert_equal 1, scope.summary_hash.dig(:result, :count)
      assert_equal "slow", scope.summary_hash.dig(:warnings, 0, :code)
    end

    def test_summary_record_input_returns_defensive_copy
      scope = build_execution_scope(type: :request, attributes: { app: { version: "one" } })
      scope.finish_owned
      first = scope.summary_record_input
      first[:attributes][:app][:version] = "changed"

      assert_equal "one", scope.summary_record_input.dig(:attributes, :app, :version)
    end

    def test_scope_label_readers_copy_non_empty_fields
      scope = build_execution_scope(
        type: :request,
        labels: { "service" => "web" }
      )

      labels = scope.labels_hash
      frozen_labels = scope.frozen_labels_hash

      labels[:service] = "changed"

      assert_equal "web", scope.labels_hash.fetch(:service)
      assert_equal "web", frozen_labels.fetch(:service)
      assert_predicate frozen_labels, :frozen?
    end

    def test_summary_increment_accumulates_counts
      scope = nil

      with_julewire_job do
        Julewire.summary.increment(:processed)
        Julewire.summary.increment(:processed, by: 4)
        scope = Julewire.current_execution
      end

      assert_equal 5, scope.summary_hash[:processed]
    end
  end
end
