# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestExecutionContext < Minitest::Test
    cover Julewire::Core::Execution::Lineage
    cover Julewire::Core::Execution::ScopeIdentity

    def test_with_execution_preserves_explicit_id
      scope = Julewire.with_execution(type: :worker, id: "scope-1", emit_summary: false) do |execution|
        execution
      end

      assert_equal "scope-1", scope.id
      assert_equal "scope-1", scope.execution_hash[:id]
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

    def test_nested_execution_scope_inherits_parent_execution_fields
      inner_execution = nil

      Julewire.with_execution(type: :outer, id: "outer", fields: { trace_id: "trace-1" }, emit_summary: false) do
        Julewire.with_execution(type: :inner, id: "inner", emit_summary: false) do
          inner_execution = Julewire.current_execution.execution_hash
        end
      end

      assert_equal "trace-1", inner_execution[:trace_id]
      assert_equal "inner", inner_execution[:id]
      assert_equal "inner", inner_execution[:type]
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

      Julewire.with_execution(type: :outer, id: "outer", emit_summary: false) do
        Julewire.attributes.add("my_app.request_method": "GET", app: { request: true })

        Julewire.with_execution(type: :inherited, emit_summary: false) do
          inherited_attributes = Julewire.current_execution.attributes_hash
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
