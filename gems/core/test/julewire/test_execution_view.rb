# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestExecutionView < Minitest::Test
    cover Julewire::Core::Execution::View
    cover Julewire::Core::Execution::ScopeSnapshot
    cover "Julewire::Core::Execution::View#execution_hash"
    cover "Julewire::Core::Execution::Scope#execution_hash"
    cover "Julewire::Core::Execution::Scope#inheritable_execution_hash"
    cover "Julewire::Core::Execution::Scope#without_carry"

    def test_with_execution_yields_public_execution_view
      Julewire.with_execution(type: :worker, emit_summary: false) do |execution|
        assert_instance_of Julewire::Core::Execution::View, execution
      end
    end

    def test_execution_view_exposes_scope_timing_readers
      started_at = Time.utc(2026, 6, 19, 10, 0, 0)
      finished_at = Time.utc(2026, 6, 19, 10, 1, 0)
      scope = Julewire::Core::Execution::Scope.new(type: :worker, id: "worker-1", started_at: started_at)
      scope.finish_owned(finished_at: finished_at)

      execution = Julewire::Core::Execution::View.new(scope)

      assert_equal "worker-1", execution.id
      assert_equal "worker", execution.type
      assert_equal started_at, execution.started_at
      assert_equal finished_at, execution.finished_at
      assert_same scope.lineage, execution.lineage
      assert_predicate execution, :finished?
    end

    def test_execution_view_reports_unfinished_scope
      scope = Julewire::Core::Execution::Scope.new(type: :worker, id: "worker-1")
      execution = Julewire::Core::Execution::View.new(scope)

      refute_predicate execution, :finished?
      assert_nil execution.finished_at
    end

    def test_scope_identity_optional_defaults_and_explicit_inputs
      identity = Julewire::Core::Execution::ScopeIdentity.new(type: :request)

      assert_equal "request", identity.type
      assert_kind_of String, identity.id
      refute_empty identity.id
      assert_kind_of Time, identity.started_at
      assert_predicate identity.started_at, :utc?
      assert_nil identity.parent
      assert_equal({ type: "request", id: identity.id }, identity.reference)
      assert_predicate identity.reference, :frozen?

      started_at = Time.utc(2026, 6, 19, 10, 0, 0)
      parent = Julewire::Core::Execution::Scope.new(type: :root, id: "root-1")
      child = Julewire::Core::Execution::ScopeIdentity.new(
        type: :job,
        id: "job-1",
        started_at: started_at,
        parent: parent,
        parent_reference: { type: "manual", id: "parent-1" }
      )

      assert_equal "job-1", child.id
      assert_equal started_at, child.started_at
      refute_same started_at, child.started_at
      assert_predicate child.started_at, :frozen?
      assert_same parent, child.parent
      assert_equal({ type: "job", id: "job-1" }, child.reference)
      assert_equal({ type: "manual", id: "parent-1" }, child.lineage.parent_reference)
    end

    def test_scope_identity_owned_execution_fields_strip_relationship_keys
      scope = Julewire::Core::Execution::Scope.new(
        type: :job,
        id: "job-1",
        execution_owned: true,
        execution: {
          type: "stale",
          id: "stale",
          ancestors: [{ type: "request", id: "request-1" }],
          payload_id: "payload-1"
        }
      )

      execution = scope.execution_hash

      assert_equal "job", execution.fetch(:type)
      assert_equal "job-1", execution.fetch(:id)
      assert_equal "payload-1", execution.fetch(:payload_id)
      refute_includes execution, :ancestors
    end

    def test_current_execution_view_readers_return_immutable_copies
      snapshot = nil

      Julewire.with_execution(type: :worker, labels: { service: "worker" }, emit_summary: false) do
        Julewire.context.add(account_id: "account-1")
        Julewire.carry.add(trace: { id: "trace-1" })
        Julewire.attributes.add(active_job: { job_id: "job-1" })
        Julewire::Core::Integration::Facade.add_neutral("job.name": "ImportJob")
        Julewire.summary.add(processed: 1)
        Julewire.summary.measure(:view) { nil }
        snapshot = Julewire.current_execution
      end

      snapshot.execution_hash[:type] = "changed"
      snapshot.context_hash[:account_id] = "changed"
      snapshot.carry_hash[:trace][:id] = "changed"
      snapshot.attributes_hash[:active_job][:job_id] = "changed"
      snapshot.neutral_hash[:"job.name"] = "ChangedJob"
      snapshot.labels_hash[:service] = "changed"
      snapshot.summary_hash[:processed] = 2
      view_duration = snapshot.metrics_hash.fetch(:view_duration_ms)
      snapshot.metrics_hash[:view_duration_ms] = 99.9

      assert_equal "worker", snapshot.execution_hash.fetch(:type)
      assert_equal "account-1", snapshot.context_hash.fetch(:account_id)
      assert_equal "trace-1", snapshot.carry_hash.dig(:trace, :id)
      assert_equal "job-1", snapshot.attributes_hash.dig(:active_job, :job_id)
      assert_equal "ImportJob", snapshot.neutral_hash.fetch(:"job.name")
      assert_equal "worker", snapshot.labels_hash.fetch(:service)
      assert_equal 1, snapshot.summary_hash.fetch(:processed)
      assert_equal view_duration, snapshot.metrics_hash.fetch(:view_duration_ms)
    end

    def test_execution_view_parent_is_an_execution_view
      parent_view = nil
      child_view = nil

      Julewire.with_execution(type: :request, id: "request-1", emit_summary: false) do
        parent_view = Julewire.current_execution
        Julewire.with_execution(type: :job, id: "job-1", emit_summary: false) do
          child_view = Julewire.current_execution
        end
      end

      assert_instance_of Julewire::Core::Execution::View, child_view.parent
      assert_same child_view.parent, child_view.parent
      assert_equal parent_view.id, child_view.parent.id
      assert_equal parent_view.type, child_view.parent.type
    end

    def test_scope_snapshot_readers_copy_non_empty_fields
      snapshot = Julewire::Core::Execution::ScopeSnapshot.new(
        execution: { "type" => "job", "id" => "job-1" },
        carry: { "trace" => { "id" => "trace-1" } },
        neutral: { "job.name" => "ImportJob" },
        attributes: { "active_job" => { "job_id" => "job-1" } },
        labels: { "service" => "worker" }
      )

      carry = snapshot.carry_hash
      neutral = snapshot.neutral_hash
      attributes = snapshot.attributes_hash
      labels = snapshot.labels_hash

      carry[:trace][:id] = "changed"
      neutral[:"job.name"] = "ChangedJob"
      attributes[:active_job][:job_id] = "changed"
      labels[:service] = "changed"

      assert_equal "trace-1", snapshot.carry_hash.dig(:trace, :id)
      assert_equal "ImportJob", snapshot.neutral_hash.fetch(:"job.name")
      assert_equal "job-1", snapshot.attributes_hash.dig(:active_job, :job_id)
      assert_equal "worker", snapshot.labels_hash.fetch(:service)
    end

    def test_scope_snapshot_execution_hash_returns_independent_copy
      snapshot = Julewire::Core::Execution::ScopeSnapshot.new(
        execution: { type: "job", metadata: { id: "meta-1" } }
      )

      execution = snapshot.execution_hash
      execution[:metadata][:id] = "changed"

      assert_equal "meta-1", snapshot.execution_hash.dig(:metadata, :id)
    end

    def test_scope_snapshot_default_sections_are_empty_hashes
      snapshot = Julewire::Core::Execution::ScopeSnapshot.new

      assert_nil snapshot.id
      assert_nil snapshot.type
      assert_nil snapshot.started_at
      assert_nil snapshot.finished_at
      assert_nil snapshot.parent
      assert_empty snapshot.execution_hash
      assert_empty snapshot.carry_hash
      assert_empty snapshot.attributes_hash
      assert_empty snapshot.neutral_hash
      assert_empty snapshot.labels_hash
      assert_empty snapshot.frozen_labels_hash
    end

    def test_scope_snapshot_preserves_explicit_lineage
      lineage = Julewire::Core::Execution::Lineage.from_execution_hash(
        type: "request",
        id: "request-1"
      )

      snapshot = Julewire::Core::Execution::ScopeSnapshot.new(
        execution: { type: "job", id: "job-1" },
        lineage: lineage
      )

      assert_same lineage, snapshot.lineage
    end

    def test_scope_snapshot_infers_lineage_from_execution_hash
      snapshot = Julewire::Core::Execution::ScopeSnapshot.new(
        execution: {
          type: "job",
          id: "job-1",
          depth: 3,
          parent: { type: "request", id: "request-1" },
          root: { type: "root", id: "root-1" }
        }
      )

      assert_equal 3, snapshot.lineage.depth
      assert_equal({ type: "request", id: "request-1" }, snapshot.lineage.parent_reference)
      assert_equal({ type: "root", id: "root-1" }, snapshot.lineage.root_reference)
    end

    def test_scope_snapshot_frozen_readers_and_child_reference
      snapshot = Julewire::Core::Execution::ScopeSnapshot.new(
        execution: { "type" => "job", "id" => "job-1" },
        labels: { "service" => "worker" }
      )

      assert_equal({ type: "job", id: "job-1" }, snapshot.execution_reference_for_child)
      assert_predicate snapshot.frozen_execution_hash, :frozen?
      assert_predicate snapshot.frozen_labels_hash, :frozen?
    end

    def test_scope_snapshot_child_reference_omits_absent_identity_fields
      type_only = Julewire::Core::Execution::ScopeSnapshot.new(execution: { "type" => "job" })
      id_only = Julewire::Core::Execution::ScopeSnapshot.new(execution: { "id" => "job-1" })
      empty = Julewire::Core::Execution::ScopeSnapshot.new

      assert_equal({ type: "job" }, type_only.execution_reference_for_child)
      assert_equal({ id: "job-1" }, id_only.execution_reference_for_child)
      assert_nil empty.execution_reference_for_child
      assert_predicate type_only.execution_reference_for_child, :frozen?
      assert_predicate id_only.execution_reference_for_child, :frozen?
    end

    def test_scope_snapshot_owned_execution_preserves_truncation_metadata
      key = Julewire::Core::Serialization::Serializer::TRUNCATION_METADATA_KEY.to_sym
      metadata = {
        truncated: true,
        truncated_fields: ["trace"],
        limits: {
          max_array_items: nil,
          max_depth: 20,
          max_hash_keys: nil,
          max_string_bytes: 10
        }
      }

      snapshot = Julewire::Core::Execution::ScopeSnapshot.new(
        execution: { trace_id: "trace-1", key => metadata },
        owned: true
      )

      assert_symbol_truncation_metadata snapshot.execution_hash.fetch(key),
                                        fields: ["trace"],
                                        max_string_bytes: 10
    end

    def test_scope_snapshot_owned_reader_returns_independent_copy
      snapshot = Julewire::Core::Execution::ScopeSnapshot.new(
        carry: { trace: { id: "trace-1" } },
        owned: true
      )

      carry = snapshot.carry_hash
      carry.fetch(:trace)[:id] = "changed"

      assert_equal "trace-1", snapshot.carry_hash.dig(:trace, :id)
    end

    def test_scope_snapshot_detaches_owned_constructor_input
      carry = { trace: { id: "trace-1" } }
      snapshot = Julewire::Core::Execution::ScopeSnapshot.new(carry: carry, owned: true)

      carry.fetch(:trace)[:id] = "changed"

      assert_equal "trace-1", snapshot.carry_hash.dig(:trace, :id)
    end

    def test_scope_snapshot_rejects_non_hash_and_string_keyed_owned_sections
      non_hash = assert_raises(TypeError) do
        Julewire::Core::Execution::ScopeSnapshot.new(carry: "trace", owned: true)
      end
      string_key = assert_raises(TypeError) do
        Julewire::Core::Execution::ScopeSnapshot.new(carry: { trace: { "id" => "trace-1" } }, owned: true)
      end

      assert_equal "owned data must be a Hash", non_hash.message
      assert_equal "record must not use string keys", string_key.message
    end

    def test_scope_snapshot_generated_truncation_metadata_survives_readers
      defaults = Julewire::Core::Serialization::Serializer
      snapshot = Julewire::Core::Execution::ScopeSnapshot.new(
        carry: { "items" => Array.new(defaults::DEFAULT_MAX_ARRAY_ITEMS + 1, "x") },
        labels: { "labels" => Array.new(defaults::DEFAULT_MAX_ARRAY_ITEMS + 1, "x") }
      )

      assert_symbol_truncation_metadata snapshot.carry_hash.dig(:items, defaults::DEFAULT_MAX_ARRAY_ITEMS,
                                                                :_julewire_truncation),
                                        fields: ["array_items"],
                                        max_array_items: defaults::DEFAULT_MAX_ARRAY_ITEMS,
                                        max_hash_keys: defaults::DEFAULT_MAX_HASH_KEYS,
                                        max_string_bytes: defaults::DEFAULT_MAX_STRING_BYTES
      assert_symbol_truncation_metadata snapshot.frozen_labels_hash.dig(:labels, defaults::DEFAULT_MAX_ARRAY_ITEMS,
                                                                        :_julewire_truncation),
                                        fields: ["array_items"],
                                        max_array_items: defaults::DEFAULT_MAX_ARRAY_ITEMS,
                                        max_hash_keys: defaults::DEFAULT_MAX_HASH_KEYS,
                                        max_string_bytes: defaults::DEFAULT_MAX_STRING_BYTES
    end

    def test_scope_snapshot_unowned_execution_rejects_truncation_metadata
      key = Julewire::Core::Serialization::Serializer::TRUNCATION_METADATA_KEY.to_sym

      error = assert_raises(ArgumentError) do
        Julewire::Core::Execution::ScopeSnapshot.new(
          execution: {
            key => {
              truncated: true,
              truncated_fields: ["trace"],
              limits: { max_depth: 20 }
            }
          }
        )
      end

      assert_equal "_julewire_truncation is reserved for Julewire truncation metadata", error.message
    end

    def test_execution_view_accepts_scope_snapshot_shape
      snapshot = Julewire::Core::Execution::ScopeSnapshot.new(
        execution: { "type" => "job", "id" => "job-1" },
        carry: { "traceparent" => "trace-1" },
        neutral: { "job.name" => "ImportJob" },
        attributes: { "active_job" => { "job_id" => "job-1" } },
        labels: { "service" => "worker" }
      )

      view = Julewire::Core::Execution::View.new(snapshot)

      assert_equal "job", view.type
      assert_equal "job-1", view.id
      assert_empty view.context_hash
      assert_equal "trace-1", view.carry_hash.fetch(:traceparent)
      assert_equal "ImportJob", view.neutral_hash.fetch(:"job.name")
      assert_equal "job-1", view.attributes_hash.dig(:active_job, :job_id)
      assert_equal "worker", view.labels_hash.fetch(:service)
      assert_empty view.summary_hash
      assert_empty view.metrics_hash
    end

    def test_scope_identity_duplicates_and_freezes_mutable_string_identity
      type = +"job"
      id = +"job-1"

      scope = Julewire::Core::Execution::Scope.new(type: type, id: id)

      refute_same type, scope.type
      refute_same id, scope.id
      assert_equal "job", scope.type
      assert_equal "job-1", scope.id
      assert_predicate scope.type, :frozen?
      assert_predicate scope.id, :frozen?

      type.replace("changed")
      id.replace("changed")

      assert_equal "job", scope.type
      assert_equal "job-1", scope.id
    end

    def test_scope_identity_reuses_frozen_string_identity
      type = "job"
      id = "job-1"

      scope = Julewire::Core::Execution::Scope.new(type: type, id: id)

      assert_same type, scope.type
      assert_same id, scope.id
    end

    def test_scope_execution_hash_returns_independent_copy
      assert_scope_execution_copy_is_independent(:execution_hash)
    end

    def test_scope_inheritable_execution_hash_returns_independent_copy
      assert_scope_execution_copy_is_independent(:inheritable_execution_hash)
    end

    def test_scope_identity_freezes_container_id
      id = { value: +"job-1" }

      scope = Julewire::Core::Execution::Scope.new(type: :job, id: id)

      refute_same id, scope.id
      assert_equal({ value: "job-1" }, scope.id)
      assert_predicate scope.id, :frozen?
      assert_predicate scope.id.fetch(:value), :frozen?

      id[:value].replace("changed")

      assert_equal "job-1", scope.id.fetch(:value)
    end

    def test_scope_with_carry_accepts_keyword_fields_and_restores_after_block
      scope = Julewire::Core::Execution::Scope.new(
        type: :job,
        carry: { trace: { id: "trace-1" } }
      )

      result = scope.with_carry(job: { id: "job-1" }) do
        assert_equal "trace-1", scope.carry_hash.dig(:trace, :id)
        assert_equal "job-1", scope.carry_hash.dig(:job, :id)
        :inside
      end

      assert_equal :inside, result
      assert_equal({ trace: { id: "trace-1" } }, scope.carry_hash)
    end

    def test_scope_with_carry_owned_preserves_truncation_metadata
      key = Julewire::Core::Serialization::Serializer::TRUNCATION_METADATA_KEY.to_sym
      metadata = {
        truncated: true,
        truncated_fields: ["trace"],
        limits: {
          max_array_items: nil,
          max_depth: 20,
          max_hash_keys: nil,
          max_string_bytes: 10
        }
      }
      scope = Julewire::Core::Execution::Scope.new(type: :job)

      error = assert_raises(ArgumentError) do
        scope.with_carry(key => metadata) { :unused }
      end

      assert_equal "_julewire_truncation is reserved for Julewire truncation metadata", error.message

      scope.with_carry({ key => metadata }, owned: true) do
        assert_symbol_truncation_metadata scope.carry_hash.fetch(key),
                                          fields: ["trace"],
                                          max_string_bytes: 10
      end

      assert_empty scope.carry_hash
    end

    def test_scope_without_carry_normalizes_path_and_restores_after_block
      scope = Julewire::Core::Execution::Scope.new(
        type: :job,
        carry: { http: { request_headers: { traceparent: "trace", authorization: "secret" } } }
      )

      inside = scope.without_carry(%w[http request_headers authorization]) do
        scope.carry_hash
      end

      assert_equal({ http: { request_headers: { traceparent: "trace" } } }, inside)
      assert_equal "secret", scope.carry_hash.dig(:http, :request_headers, :authorization)
    end

    def test_scope_without_carry_rejects_empty_path
      scope = Julewire::Core::Execution::Scope.new(type: :job)

      error = assert_raises(ArgumentError) do
        scope.without_carry([]) { :unused }
      end

      assert_equal "carry path is required", error.message

      error = assert_raises(ArgumentError) do
        scope.without_carry([[]]) { :unused }
      end

      assert_equal "carry path is required", error.message
    end

    def test_current_execution_parent_can_read_linked_propagation_snapshot
      parent = nil

      Julewire::Core::Propagation.restore(
        {
          execution: { "type" => "request", "id" => "request-1" },
          context: { "request_id" => "req-1" }
        },
        link_executions: true
      ) do
        Julewire.with_execution(type: :job, id: "job-1", emit_summary: false) do
          parent = Julewire.current_execution.parent
        end
      end

      assert_equal "request", parent.type
      assert_equal "request-1", parent.id
      assert_nil parent.parent
      assert_empty parent.context_hash
      assert_empty parent.summary_hash
      assert_empty parent.metrics_hash
    end

    private

    def assert_scope_execution_copy_is_independent(reader)
      scope = Julewire::Core::Execution::Scope.new(
        type: :job,
        execution: { nested: { id: "job-1" } },
        execution_owned: true
      )

      copy = scope.public_send(reader)
      copy[:nested][:id] = "changed"

      assert_equal "job-1", scope.public_send(reader).dig(:nested, :id)
    end
  end
end
