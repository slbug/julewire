# frozen_string_literal: true

require "test_helper"
require "json"
require "stringio"

module Julewire
  class TestExecutionLineage < Minitest::Test
    cover Julewire::Core::Execution::Lineage

    def test_clean_helpers_tolerate_non_hash_inputs
      assert_empty Julewire::Core::Execution::Lineage.clean_execution_hash("nope")
      assert_empty Julewire::Core::Execution::Lineage.clean_normalized_lazy_relationship_hash("nope")
    end

    def test_from_execution_hash_tolerates_non_hash_inputs
      lineage = Julewire::Core::Execution::Lineage.from_execution_hash("nope")

      assert_equal 1, lineage.depth
      assert_empty lineage.ancestors
      refute_predicate lineage, :truncated?
    end

    def test_from_execution_hash_captures_lazy_ancestors
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

    def test_lineage_accessor_materializes_bounded_parent_chain
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
        assert_equal level_reference(1), lineage.root_reference
        assert_equal expected_ancestors, lineage.ancestors
        assert_equal depth > max_ancestors + 1, lineage.truncated?
      end
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
