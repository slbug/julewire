# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestExecutionView < Minitest::Test
    def test_current_execution_view_readers_return_immutable_copies
      snapshot = nil

      Julewire.with_execution(type: :worker, emit_summary: false) do
        Julewire.context.add(account_id: "account-1")
        Julewire::Core::Integration::Facade.add_neutral("job.name": "ImportJob")
        Julewire.summary.add(processed: 1)
        snapshot = Julewire.current_execution
      end

      snapshot.context_hash[:account_id] = "changed"
      snapshot.neutral_hash[:"job.name"] = "ChangedJob"
      snapshot.summary_hash[:processed] = 2

      assert_equal "account-1", snapshot.context_hash.fetch(:account_id)
      assert_equal "ImportJob", snapshot.neutral_hash.fetch(:"job.name")
      assert_equal 1, snapshot.summary_hash.fetch(:processed)
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

    def test_scope_snapshot_frozen_readers_and_child_reference
      snapshot = Julewire::Core::Execution::ScopeSnapshot.new(
        execution: { "type" => "job", "id" => "job-1" },
        labels: { "service" => "worker" }
      )

      assert_equal({ type: "job", id: "job-1" }, snapshot.execution_reference_for_child)
      assert_predicate snapshot.frozen_labels_hash, :frozen?
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
  end
end
