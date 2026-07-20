# frozen_string_literal: true

require "test_helper"
require "json"
require "stringio"

module Julewire
  class TestExecutionLineage < Minitest::Test
    cover Julewire::Core::Execution::Lineage
    cover "Julewire::Core::Execution::Lineage.execution_reference"

    def test_non_array_ancestors_are_ignored
      lineage = Julewire::Core::Execution::Lineage.new(ancestors: { type: "request" })

      assert_equal [], lineage.ancestors
    end

    def test_array_subclass_ancestors_are_copied_and_frozen
      ancestors = Class.new(Array).new([{ type: "request", id: "request-1" }])
      lineage = Julewire::Core::Execution::Lineage.new(ancestors: ancestors)

      assert_equal [{ type: "request", id: "request-1" }], lineage.ancestors
      assert_predicate lineage.ancestors.first, :frozen?
    end

    def test_clean_helpers_tolerate_non_hash_inputs
      assert_empty Julewire::Core::Execution::Lineage.clean_execution_hash("nope")
      assert_empty Julewire::Core::Execution::Lineage.clean_normalized_lazy_relationship_hash("nope")
    end

    def test_clean_helpers_accept_hash_subclasses
      execution = Class.new(Hash).new.merge!(
        "type" => "job",
        "id" => "job-1",
        "ancestors" => [{ "id" => "root" }]
      )

      assert_equal(
        { type: "job", id: "job-1" },
        Julewire::Core::Execution::Lineage.clean_execution_hash(execution)
      )
    end

    def test_clean_normalized_lazy_relationship_hash_accepts_hash_subclasses_without_mutating_input
      execution = Class.new(Hash).new.merge!(
        type: "job",
        id: "job-1",
        ancestors: [{ id: "root" }]
      )

      cleaned = Julewire::Core::Execution::Lineage.clean_normalized_lazy_relationship_hash(execution)

      assert_equal({ type: "job", id: "job-1" }, cleaned)
      assert_equal [{ id: "root" }], execution.fetch(:ancestors)
    end

    def test_from_execution_hash_tolerates_non_hash_inputs
      lineage = Julewire::Core::Execution::Lineage.from_execution_hash("nope")

      assert_equal 1, lineage.depth
      assert_nil lineage.root_reference
      assert_empty lineage.ancestors
      refute_predicate lineage, :truncated?
    end

    def test_from_execution_hash_has_no_root_reference_without_type_or_id
      lineage = Julewire::Core::Execution::Lineage.from_execution_hash(attributes: { hidden: true })

      assert_nil lineage.root_reference
    end

    def test_from_execution_hash_captures_ancestors
      lineage = Julewire::Core::Execution::Lineage.from_execution_hash(
        type: "job",
        id: "job-1",
        root: { type: "request", id: "request-1" },
        parent: { type: "worker", id: "worker-1" },
        depth: 3,
        ancestors: [{ type: "request", id: "request-1" }],
        ancestors_truncated: true
      )

      assert_equal 3, lineage.depth
      assert_equal({ type: "request", id: "request-1" }, lineage.root_reference)
      assert_equal({ type: "worker", id: "worker-1" }, lineage.parent_reference)
      assert_equal [{ type: "request", id: "request-1" }], lineage.ancestors
      assert_predicate lineage, :truncated?
    end

    def test_from_execution_hash_uses_type_and_id_as_root_reference
      lineage = Julewire::Core::Execution::Lineage.from_execution_hash(type: "job", id: "job-1")

      assert_equal({ type: "job", id: "job-1" }, lineage.root_reference)
    end

    def test_from_execution_hash_preserves_partial_references
      type_lineage = Julewire::Core::Execution::Lineage.from_execution_hash(type: "job")
      id_lineage = Julewire::Core::Execution::Lineage.from_execution_hash(id: "job-1")

      assert_equal({ type: "job" }, type_lineage.root_reference)
      assert_equal({ id: "job-1" }, id_lineage.root_reference)
    end

    def test_lineage_ignores_non_positive_explicit_depth
      parent = Julewire::Core::Execution::Lineage.new(reference: { type: "parent", id: "parent-1" }, depth: 3)
      child = Julewire::Core::Execution::Lineage.new(
        reference: { type: "child", id: "child-1" },
        parent_lineage: parent,
        parent_reference: { type: "parent", id: "parent-1" },
        depth: 0
      )
      root = Julewire::Core::Execution::Lineage.new(reference: { type: "root", id: "root-1" }, depth: -1)

      assert_equal 4, child.depth
      assert_equal 1, root.depth
    end

    def test_lineage_ignores_non_integer_positive_depth_objects
      depth = Object.new
      depth.define_singleton_method(:positive?) { true }

      lineage = Julewire::Core::Execution::Lineage.new(reference: { type: "job", id: "job-1" }, depth: depth)

      assert_equal 1, lineage.depth
    end

    def test_lineage_treats_false_relationship_references_as_absent
      lineage = Julewire::Core::Execution::Lineage.new(
        reference: { type: "job", id: "job-1" },
        parent_reference: false,
        root_reference: false
      )

      assert_equal({ type: "job", id: "job-1" }, lineage.root_reference)
      assert_nil lineage.parent_reference
      assert_empty lineage.ancestors
    end

    def test_lineage_copies_and_freezes_direct_relationship_references
      root = { type: "request", id: "request-1" }
      parent = { type: "job", id: "job-1" }
      lineage = Julewire::Core::Execution::Lineage.new(root_reference: root, parent_reference: parent)

      root[:id] = "changed"
      parent[:id] = "changed"

      assert_equal({ type: "request", id: "request-1" }, lineage.root_reference)
      assert_equal({ type: "job", id: "job-1" }, lineage.parent_reference)
      assert_raises(FrozenError) { lineage.root_reference[:id] = "changed-again" }
      assert_raises(FrozenError) { lineage.parent_reference[:id] = "changed-again" }
    end

    def test_lineage_truncation_input_is_normalized_to_boolean
      lineage = Julewire::Core::Execution::Lineage.new(ancestors_truncated: "yes")
      default_lineage = Julewire::Core::Execution::Lineage.new
      explicit_lineage = Julewire::Core::Execution::Lineage.new(ancestors: [])

      assert_true lineage.truncated?
      assert_false default_lineage.truncated?
      assert_false explicit_lineage.truncated?
    end

    def test_lineage_accessor_snapshots_bounded_parent_chain
      root = Julewire::Core::Execution::Lineage.new(reference: { type: "root", id: "root-1" })
      child = Julewire::Core::Execution::Lineage.new(
        reference: { type: "child", id: "child-1" },
        parent_lineage: root,
        parent_reference: { type: "root", id: "root-1" }
      )

      assert_equal 2, child.depth
      assert_equal({ type: "root", id: "root-1" }, child.root_reference)
      assert_equal({ type: "root", id: "root-1" }, child.parent_reference)
      assert_equal [{ type: "root", id: "root-1" }], child.ancestors
    end

    def test_nested_execution_scope_records_relationship_metadata
      inner_execution = nil

      with_outer_middle_inner_execution do |execution|
        inner_execution = execution.execution_hash
      end

      assert_equal 3, inner_execution[:depth]
      assert_equal({ type: "outer", id: "outer" }, inner_execution[:root])
      assert_equal({ type: "middle", id: "middle" }, inner_execution[:parent])
      refute_includes inner_execution, :ancestors
      refute_includes inner_execution, :ancestors_truncated
    end

    def test_nested_execution_scope_exposes_ancestors_through_lineage_accessor
      lineage = nil

      with_outer_middle_inner_execution do |execution|
        lineage = execution.lineage
      end

      assert_equal(
        [{ type: "outer", id: "outer" }, { type: "middle", id: "middle" }],
        lineage.ancestors
      )
      refute_predicate lineage, :truncated?
    end

    def test_execution_ancestors_are_bounded_without_dropping_context
      current_context = nil
      current_execution = nil
      current_lineage = nil

      with_nested_executions(58) do
        current_context = Julewire.context.to_h
        snapshot = Julewire.current_execution
        current_execution = snapshot.execution_hash
        current_lineage = snapshot.lineage
      end

      first_level = 1
      last_level = 58

      assert_bounded_lineage(
        current_context,
        current_execution,
        current_lineage,
        first_level: first_level,
        last_level: last_level
      )
    end

    def test_lineage_chain_properties_hold_for_fixed_seed_depths
      random = Random.new(0x42)
      max_ancestors = Julewire::Core::Execution::Lineage::MAX_ANCESTORS

      25.times do
        depth = random.rand(1..(max_ancestors + 30))
        lineage = build_lineage_chain(depth)
        expected_ancestors = (1...depth).map { level_reference(it) }.last(max_ancestors)

        assert_equal depth, lineage.depth
        unless level_reference(1) == lineage.root_reference
          flunk "lineage root reference must preserve the root execution"
        end

        assert_equal expected_ancestors, lineage.ancestors
        assert_equal depth > max_ancestors + 1, lineage.truncated?
      end
    end

    def test_lineage_truncation_checks_bounded_parent_chain
      max_ancestors = Julewire::Core::Execution::Lineage::MAX_ANCESTORS

      refute_predicate build_lineage_chain(max_ancestors + 1), :truncated?
      assert_predicate build_lineage_chain(max_ancestors + 2), :truncated?
    end

    def test_lineage_truncation_keeps_explicit_ancestors_authoritative
      max_ancestors = Julewire::Core::Execution::Lineage::MAX_ANCESTORS
      parent = build_lineage_chain(max_ancestors + 3)
      lineage = Julewire::Core::Execution::Lineage.new(
        reference: level_reference(100),
        parent_lineage: parent,
        parent_reference: level_reference(99),
        ancestors: [level_reference(1)]
      )

      assert_equal [level_reference(1)], lineage.ancestors
      assert_predicate lineage.ancestors, :frozen?
      refute_predicate lineage, :truncated?
    end

    def test_execution_relationship_hash_does_not_mutate_scope_lineage
      second_snapshot = nil

      Julewire.with_execution(type: :outer, id: "outer", emit_summary: false) do
        Julewire.with_execution(type: :inner, id: "inner", emit_summary: false) do
          first = Julewire.current_execution
          first_snapshot = first.execution_hash
          first_snapshot[:root][:id] = "changed"
          first_snapshot[:parent][:id] = "changed"

          second = Julewire.current_execution
          second_snapshot = second.execution_hash
        end
      end

      assert_equal({ type: "outer", id: "outer" }, second_snapshot[:root])
      assert_equal({ type: "outer", id: "outer" }, second_snapshot[:parent])
    end

    def test_lineage_merge_into_frozen_owns_non_relationship_fields
      payload = { nested: ["original"] }
      lineage = Julewire::Core::Execution::Lineage.new(reference: { type: "job", id: "job-1" })
      merged = lineage.merge_into_frozen(type: "job", id: "job-1", payload: payload)

      payload.fetch(:nested) << "changed"

      assert_equal ["original"], merged.dig(:payload, :nested)
      assert_predicate merged, :frozen?
      assert_predicate merged.fetch(:payload), :frozen?
      assert_predicate merged.dig(:payload, :nested), :frozen?
    end

    def test_lineage_merge_into_frozen_omits_absent_parent_reference
      lineage = Julewire::Core::Execution::Lineage.new(reference: { type: "job", id: "job-1" })

      merged = lineage.merge_into_frozen(type: "job", id: "job-1")

      refute_includes merged, :parent
    end

    def test_parent_lineage_without_parent_reference_does_not_append_nil_ancestor
      parent = Julewire::Core::Execution::Lineage.new(reference: { type: "parent", id: "parent-1" })
      child = Julewire::Core::Execution::Lineage.new(
        reference: { type: "child", id: "child-1" },
        parent_lineage: parent
      )

      assert_empty child.ancestors
      refute_predicate child, :truncated?
    end

    def test_parent_reference_without_parent_lineage_does_not_raise
      lineage = Julewire::Core::Execution::Lineage.new(
        reference: { type: "child", id: "child-1" },
        parent_reference: { type: "parent", id: "parent-1" }
      )

      assert_empty lineage.ancestors
      refute_predicate lineage, :truncated?
    end

    def test_lineage_relationship_accessors_return_immutable_snapshots
      with_outer_middle_inner_execution do |execution|
        ancestors = execution.lineage.ancestors

        assert_raises(FrozenError) { execution.lineage.root_reference[:id] = "changed" }
        assert_raises(FrozenError) { execution.lineage.parent_reference[:id] = "changed" }
        assert_raises(FrozenError) { ancestors.first[:id] = "changed" }
        assert_raises(FrozenError) { ancestors << { type: "other", id: "other" } }
      end
    end

    def test_processors_can_promote_lineage_with_explicit_accessor
      output = StringIO.new
      Julewire.configure do |config|
        configure_destination(config, output: output)
        config.processors.use(lineage_promoting_processor)
      end

      Julewire.with_execution(type: :request, id: "request-1", emit_summary: false) do
        Julewire.with_execution(type: :job, id: "job-1", emit_summary: false) do
          Julewire.emit(event: "job.tick")
        end
      end

      record = JSON.parse(output.string)

      assert_equal(
        { "ancestor_count" => 1, "execution_depth" => 2, "root_execution_id" => "request-1" },
        record.fetch("labels")
      )
      refute_includes record.fetch("execution"), "depth"
      refute_includes record.fetch("execution"), "root"
    end

    private

    def lineage_promoting_processor
      lambda do |record|
        record[:labels][:execution_depth] = record.lineage.depth
        record[:labels][:root_execution_id] = record.lineage.root_reference[:id]
        record[:labels][:ancestor_count] = record.lineage.ancestors.length
        nil
      end
    end

    def assert_bounded_lineage(context, execution, lineage, first_level:, last_level:)
      max_ancestors = Julewire::Core::Execution::Lineage::MAX_ANCESTORS
      first_ancestor_level = last_level - 1 - max_ancestors + 1

      assert_equal first_level, context[:"level_#{first_level}"]
      assert_equal last_level, context[:"level_#{last_level}"]
      assert_equal last_level, execution[:depth]
      assert_equal level_reference(first_level), execution[:root]
      assert_equal level_reference(last_level - 1), execution[:parent]
      assert_equal max_ancestors, lineage.ancestors.length
      assert_equal level_reference(first_ancestor_level), lineage.ancestors.first
      assert_equal level_reference(last_level - 1), lineage.ancestors.last
      assert_predicate lineage, :truncated?
    end

    def level_reference(level)
      { type: "level_#{level}", id: "level-#{level}" }
    end

    def build_lineage_chain(depth)
      lineage = Julewire::Core::Execution::Lineage.new(reference: level_reference(1))
      (2..depth).each do |level|
        lineage = Julewire::Core::Execution::Lineage.new(
          reference: level_reference(level),
          parent_lineage: lineage,
          parent_reference: level_reference(level - 1)
        )
      end
      lineage
    end

    def with_nested_executions(depth, level: 1, &)
      Julewire.with_execution(type: :"level_#{level}", id: "level-#{level}", emit_summary: false) do
        Julewire.context.add("level_#{level}" => level)

        if level == depth
          yield
        else
          with_nested_executions(depth, level: level + 1, &)
        end
      end
    end

    def with_outer_middle_inner_execution
      Julewire.with_execution(type: :outer, id: "outer", emit_summary: false) do
        Julewire.with_execution(type: :middle, id: "middle", emit_summary: false) do
          Julewire.with_execution(type: :inner, id: "inner", emit_summary: false) do
            yield Julewire.current_execution
          end
        end
      end
    end
  end
end
