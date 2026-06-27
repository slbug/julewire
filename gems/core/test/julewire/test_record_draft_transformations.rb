# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestRecordDraftTransformations < Minitest::Test
    cover Julewire::Core::Records::Draft

    def test_transform_helpers_reject_finalized_drafts_without_yielding
      draft = Core::Records::Draft.build(
        { severity: :info, payload: { count: 1 } },
        context: {},
        scope: nil
      )
      draft.to_record
      yielded = []

      field_error = assert_raises(FrozenError) do
        draft.transform_field!(:severity) { yielded << :field }
      end
      section_error = assert_raises(FrozenError) do
        draft.transform_section!(:payload) { yielded << :section }
      end
      record_error = assert_raises(FrozenError) do
        draft.transform_record! { yielded << :record }
      end

      assert_empty yielded
      [field_error, section_error, record_error].each do |error|
        assert_equal "can't transform a finalized record draft", error.message
      end
    end

    def test_transform_field_rejects_unknown_record_fields
      draft = Core::Records::Draft.build({ message: "hello" }, context: {}, scope: nil)

      error = assert_raises(ArgumentError) do
        draft.transform_field!(:custom_field) { flunk "unknown field yielded" }
      end

      assert_equal "unknown record field: custom_field", error.message
    end

    def test_transform_field_can_restore_a_missing_known_field
      draft = Core::Records::Draft.build({ message: "hello" }, context: {}, scope: nil)
      draft.transform_record! { it.except(:severity) }
      seen = :not_called

      result = draft.transform_field!(:severity) do |value|
        seen = value
        :warn
      end

      assert_same draft, result
      assert_nil seen
      assert_equal :warn, draft.to_record.fetch(:severity)
    end

    def test_transform_section_preserves_record_shape
      draft = Core::Records::Draft.build({ payload: { token: "secret" } }, context: {}, scope: nil)

      error = assert_raises(TypeError) do
        draft.transform_section!(:payload) { nil }
      end

      assert_equal "record payload must be a Hash", error.message
      assert_equal({ token: "secret" }, draft.fetch(:payload))
    end

    def test_transform_section_rejects_truthy_non_hash_replacements
      draft = Core::Records::Draft.build({ payload: { token: "secret" } }, context: {}, scope: nil)

      error = assert_raises(TypeError) do
        draft.transform_section!(:payload) { Object.new }
      end

      assert_equal "record payload must be a Hash", error.message
      assert_equal({ token: "secret" }, draft.fetch(:payload))
    end

    def test_transform_section_accepts_hash_subclass_replacements_and_returns_draft
      draft = Core::Records::Draft.build({ payload: { token: "secret" } }, context: {}, scope: nil)
      replacement = Class.new(Hash).new.merge!(transformed: true)

      result = draft.transform_section!(:payload) { replacement }

      assert_same draft, result
      assert_true draft.dig(:payload, :transformed)
    end

    def test_transform_helpers_reject_string_keys
      draft = Core::Records::Draft.build({ payload: { token: "secret" } }, context: {}, scope: nil)

      field_error = assert_raises(TypeError) { draft.transform_field!("severity") { flunk } }
      section_error = assert_raises(TypeError) { draft.transform_section!("payload") { flunk } }

      assert_equal "record transform field must be a Symbol", field_error.message
      assert_equal "record transform section must be a Symbol", section_error.message
    end

    def test_transform_section_allows_missing_sections_to_be_restored
      draft = Core::Records::Draft.build({ payload: { token: "secret" } }, context: {}, scope: nil)
      draft.transform_record! { it.except(:payload) }
      seen_section = :not_called

      result = draft.transform_section!(:payload) do |section|
        seen_section = section
        { restored: true }
      end

      assert_same draft, result
      assert_nil seen_section
      assert_true draft.to_record.dig(:payload, :restored)
    end

    def test_transform_field_can_follow_a_frozen_whole_record_replacement
      draft = Core::Records::Draft.build({ payload: { count: 1 } }, context: {}, scope: nil)

      transform_result = draft.transform_record! { |data| data.merge(payload: { count: 2 }).freeze }
      result = draft.transform_field!(:severity) { :warn }
      record = draft.to_record

      assert_same draft, transform_result
      assert_same draft, result
      assert_equal :warn, record.fetch(:severity)
      assert_equal 2, record.dig(:payload, :count)
    end

    def test_transform_record_missing_execution_fails_with_record_validation
      draft = Core::Records::Draft.build({ payload: { count: 1 } }, context: {}, scope: nil)

      draft.transform_record! { |data| data.except(:execution) }
      error = assert_raises(TypeError) { draft.to_record }

      assert_equal "record must be complete (missing: execution)", error.message
    end

    def test_transform_record_preserves_lineage_when_execution_relationship_unchanged
      ancestors = [{ type: "request", id: "request-1" }]
      draft = Core::Records::Draft.build(record_input(ancestors: ancestors), context: {}, scope: nil)

      draft.transform_record! { |data| data.merge(payload: { token: "[FILTERED]" }) }
      record = draft.to_record

      assert_equal ancestors, record.lineage.ancestors
      assert_false record[:execution].key?(:ancestors)
    end

    def test_transform_record_preserves_lineage_when_replacement_reuses_execution_hash
      ancestors = [{ type: "request", id: "request-1" }]
      draft = Core::Records::Draft.build(record_input(ancestors: ancestors), context: {}, scope: nil)
      draft.lineage

      draft.transform_record! do |data|
        data.merge(execution: data.fetch(:execution), payload: { token: "[FILTERED]" })
      end
      record = draft.to_record

      assert_equal ancestors, record.lineage.ancestors
      assert_false record.fetch(:execution).key?(:ancestors)
    end

    def test_transform_record_preserves_materialized_lineage_when_execution_identity_stays_same
      ancestors = [{ type: "request", id: "request-1" }]
      input = record_input(ancestors: ancestors)
      input.fetch(:execution)[:tenant] = "old"
      draft = Core::Records::Draft.build(input, context: {}, scope: nil)
      draft.lineage

      draft.transform_record! do |data|
        data.merge(execution: { type: data.dig(:execution, :type), id: data.dig(:execution, :id), secret: "kept" })
      end
      record = draft.to_record

      assert_equal ancestors, record.lineage.ancestors
      assert_equal "kept", record.dig(:execution, :secret)
    end

    def test_transform_record_preserves_lineage_for_equivalent_hash_subclass_execution
      ancestors = [{ type: "request", id: "request-1" }]
      draft = Core::Records::Draft.build(record_input(ancestors: ancestors), context: {}, scope: nil)
      execution = Class.new(Hash).new.merge!(type: "job", id: "job-1", secret: "kept")

      draft.transform_record! { |data| data.merge(execution: execution) }
      record = draft.to_record

      assert_equal ancestors, record.lineage.ancestors
      assert_equal "job-1", record.dig(:execution, :id)
      assert_equal "kept", record.dig(:execution, :secret)
      assert_false record[:execution].key?(:depth)
      assert_false record[:execution].key?(:root)
      assert_false record[:execution].key?(:parent)
    end

    def test_transform_record_preserves_lineage_for_equivalent_top_level_hash_subclass
      ancestors = [{ type: "request", id: "request-1" }]
      draft = Core::Records::Draft.build(record_input(ancestors: ancestors), context: {}, scope: nil)

      draft.transform_record! do |data|
        Class.new(Hash).new.merge!(data, payload: { transformed: true })
      end

      record = draft.to_record

      assert_equal ancestors, record.lineage.ancestors
      assert_true record.dig(:payload, :transformed)
    end

    def test_transform_record_rebuilds_lineage_for_non_hash_execution
      ancestors = [{ type: "request", id: "request-1" }]
      draft = Core::Records::Draft.build(record_input(ancestors: ancestors), context: {}, scope: nil)

      draft.transform_record! { |data| data.merge(execution: "bad") }

      assert_empty draft.lineage.ancestors
      assert_nil draft.lineage.root_reference
    end

    def test_transform_record_rebuilds_lineage_for_explicit_nil_identity_key
      ancestors = [{ type: "request", id: "request-1" }]
      draft = Core::Records::Draft.build(record_input(ancestors: ancestors), context: {}, scope: nil)

      draft.transform_record! { |data| data.merge(execution: { type: "job", id: "job-1", depth: nil }) }
      record = draft.to_record

      assert_empty record.lineage.ancestors
      assert_equal({ type: "job", id: "job-1" }, record.lineage.root_reference)
      assert_nil record.dig(:execution, :depth)
      assert_true record.fetch(:execution).key?(:depth)
    end

    def test_transform_record_rebuilds_lineage_when_identity_key_is_removed
      ancestors = [{ type: "request", id: "request-1" }]
      draft = Core::Records::Draft.build(
        { execution: { type: "same", id: "same", ancestors: ancestors } },
        context: {},
        scope: nil
      )

      draft.transform_record! { |data| data.merge(execution: { type: "same" }) }

      assert_empty draft.lineage.ancestors
      assert_equal({ type: "same" }, draft.lineage.root_reference)
    end

    def test_transform_record_rebuilds_lineage_when_execution_relationship_changes
      draft = Core::Records::Draft.build(record_input, context: {}, scope: nil)

      draft.transform_record! { |data| data.merge(execution: { type: "job", id: "job-2" }) }
      record = draft.to_record

      assert_empty record.lineage.ancestors
      assert_equal({ type: "job", id: "job-2" }, record.lineage.root_reference)
    end

    def test_lineage_uses_scope_execution_when_input_omits_execution
      parent_scope = Core::Execution::Scope.new(type: :request, id: "request-1")
      child_scope = Core::Execution::Scope.new(type: :job, id: "job-1", parent: parent_scope)

      draft = Core::Records::Draft.build({}, context: {}, scope: child_scope)

      assert_equal({ type: "request", id: "request-1" }, draft.lineage.root_reference)
      assert_equal 2, draft.lineage.depth
    end

    def test_transform_section_preserves_lineage_when_execution_identity_is_unchanged
      ancestors = [{ type: "request", id: "request-1" }]
      draft = Core::Records::Draft.build(record_input(ancestors: ancestors), context: {}, scope: nil)
      lineage = draft.lineage

      draft.transform_section!(:execution) { it.merge(access_token: "secret") }
      record = draft.to_record

      assert_same lineage, record.lineage
      assert_equal "secret", record.dig(:execution, :access_token)
      assert_equal ancestors, record.lineage.ancestors
    end

    def test_transform_section_preserves_lineage_when_extra_execution_fields_change
      ancestors = [{ type: "request", id: "request-1" }]
      draft = Core::Records::Draft.build(
        {
          execution: {
            type: "job",
            id: "job-1",
            subsystem: "worker",
            ancestors: ancestors
          }
        },
        context: {},
        scope: nil
      )

      draft.transform_section!(:execution) { it.merge(subsystem: "critical-worker") }
      record = draft.to_record

      assert_equal "critical-worker", record.dig(:execution, :subsystem)
      assert_equal ancestors, record.lineage.ancestors
    end

    def test_transform_field_rebuilds_lineage_when_execution_identity_changes
      draft = Core::Records::Draft.build({}, context: {}, scope: nil)

      draft.transform_field!(:execution) do
        {
          type: "job",
          id: "job-1",
          ancestors: [{ type: "request", id: "request-1" }]
        }
      end
      record = draft.to_record

      assert_equal "job-1", record.dig(:execution, :id)
      assert_equal [{ type: "request", id: "request-1" }], record.lineage.ancestors
    end

    private

    def record_input(ancestors: [{ type: "request", id: "request-1" }])
      {
        execution: {
          type: "job",
          id: "job-1",
          ancestors: ancestors
        },
        payload: { token: "secret" }
      }
    end
  end
end
