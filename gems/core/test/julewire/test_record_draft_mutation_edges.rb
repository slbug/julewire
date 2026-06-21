# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestRecordDraftMutationEdges < Minitest::Test
    cover Julewire::Core::Execution::Lineage

    def test_mutable_record_draft_freezes_nested_values_inside_shallow_frozen_containers
      draft = Core::Records::Draft.build(
        {
          payload: {
            frozen_hash: { values: [] }.freeze,
            frozen_array: [{ value: "x" }].freeze
          }
        },
        context: {},
        scope: nil,
        freeze_sections: false
      )

      record = draft.to_record

      assert_predicate record.dig(:payload, :frozen_hash, :values), :frozen?
      assert_predicate record.dig(:payload, :frozen_array, 0), :frozen?
    end

    def test_record_draft_from_immutable_record_can_round_trip_without_mutation
      record = Core::Records::Draft.build({ payload: { count: 1 } }, context: {}, scope: nil).to_record

      round_trip = Core::Records::Draft.from_record(record).to_record

      assert_equal({ count: 1 }, round_trip.fetch(:payload))
      assert_predicate record.fetch(:payload), :frozen?
    end

    def test_transform_field_invalidates_cached_record
      draft = Core::Records::Draft.build(
        { severity: :info, payload: { count: 1 } },
        context: {},
        scope: nil,
        freeze_sections: false
      )
      first = draft.to_record

      draft.transform_field!("severity") { :warn }
      second = draft.to_record

      refute_same first, second
      assert_equal :warn, second.fetch(:severity)
    end

    def test_transform_section_preserves_record_shape
      draft = Core::Records::Draft.build({ payload: { token: "secret" } }, context: {}, scope: nil)

      error = assert_raises(TypeError) do
        draft.transform_section!(:payload) { nil }
      end

      assert_equal "record payload must be a Hash", error.message
      assert_equal({ token: "secret" }, draft.fetch(:payload))
    end

    def test_transform_record_invalidates_cached_record
      draft = Core::Records::Draft.build({ payload: { count: 1 } }, context: {}, scope: nil)
      first = draft.to_record

      draft.transform_record! { |data| data.merge(payload: { count: 2 }) }
      second = draft.to_record

      refute_same first, second
      assert_equal 2, second.dig(:payload, :count)
    end

    def test_transform_record_preserves_lineage_when_execution_relationship_unchanged
      ancestors = [{ type: "request", id: "request-1" }]
      draft = Core::Records::Draft.build(record_input(ancestors: ancestors), context: {}, scope: nil)

      draft.transform_record! { |data| data.merge(payload: { token: "[FILTERED]" }) }
      record = draft.to_record

      assert_equal ancestors, record.lineage.ancestors
      refute record[:execution].key?(:ancestors)
    end

    def test_transform_record_rebuilds_lineage_when_execution_relationship_changes
      draft = Core::Records::Draft.build(record_input, context: {}, scope: nil)

      draft.transform_record! { |data| data.merge(execution: { type: "job", id: "job-2" }) }
      record = draft.to_record

      assert_empty record.lineage.ancestors
      assert_equal({ type: "job", id: "job-2" }, record.lineage.root_reference)
    end

    def test_transform_section_preserves_lineage_when_execution_identity_is_unchanged
      ancestors = [{ type: "request", id: "request-1" }]
      draft = Core::Records::Draft.build(record_input(ancestors: ancestors), context: {}, scope: nil)
      first = draft.to_record

      draft.transform_section!(:execution) { it.merge(access_token: "secret") }
      second = draft.to_record

      refute_same first, second
      assert_equal "secret", second.dig(:execution, :access_token)
      assert_equal ancestors, second.lineage.ancestors
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
