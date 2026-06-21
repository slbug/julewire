# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestRecordDraft < Minitest::Test
    cover Julewire::Core::Execution::Lineage
    cover Julewire::Core::Serialization::ValueCopy

    def test_record_draft_allows_direct_mutation_before_final_immutable_record
      draft = Julewire::Core::Records::Draft.build(
        { payload: { "token" => "secret" } },
        context: {},
        scope: nil,
        freeze_sections: false
      )

      draft[:payload][:token] = "[FILTERED]"
      draft[:payload][:processed] = true
      draft[:severity] = :warn

      record = draft.to_record

      assert_instance_of Julewire::Core::Records::Record, record
      assert_equal :warn, record.fetch(:severity)
      assert_equal({ token: "[FILTERED]", processed: true }, record.fetch(:payload))
      assert_predicate record.fetch(:payload), :frozen?
    end

    def test_record_draft_defers_direct_mutation_validation_until_record_boundary
      draft = Julewire::Core::Records::Draft.build({}, context: {}, scope: nil)

      draft[:kind] = :bad
      error = assert_raises(TypeError) { draft.to_record }

      assert_equal "record kind must be :point or :summary", error.message
    end

    def test_record_draft_defers_direct_section_validation_until_record_boundary
      draft = draft_with_payload

      draft[:payload] = nil
      error = assert_raises(TypeError) { draft.to_record }

      assert_equal "record payload must be a Hash", error.message
    end

    def test_record_draft_can_be_built_from_immutable_record_without_sharing_sections
      record = Julewire::Core::Records::Draft.build({ payload: { count: 1 } }, context: {}, scope: nil).to_record

      draft = Julewire::Core::Records::Draft.from_record(record, freeze_sections: false)
      draft[:payload] = { count: 2 }

      assert_equal({ count: 1 }, record.fetch(:payload))
      assert_equal({ count: 2 }, draft.fetch(:payload))
    end

    def test_record_draft_builds_attributes_section
      record = Julewire::Core::Records::Draft.build(
        {
          attributes: {
            "my_app.request_method" => "GET",
            web: { "controller" => "HomeController" }
          }
        },
        context: {},
        scope: nil
      ).to_record

      assert_equal "GET", record.dig(:attributes, :"my_app.request_method")
      assert_equal "HomeController", record.dig(:attributes, :web, :controller)
    end

    def test_record_draft_copies_scope_execution_without_explicit_execution_input
      scope = build_execution_scope(
        type: :request,
        id: "request-1",
        execution: { custom: { ids: ["one"] } }
      )

      draft = Julewire::Core::Records::Draft.build({}, context: {}, scope: scope)
      record = draft.to_record

      assert_equal ["one"], record.dig(:execution, :custom, :ids)
      assert_equal ["one"], scope.execution_hash.dig(:custom, :ids)
      assert_raises(FrozenError) { record.dig(:execution, :custom, :ids) << "two" }
    end

    def test_record_draft_deep_merges_input_attributes_with_base_attributes
      record = Julewire::Core::Records::Draft.build(
        { attributes: { web: { action: "index" } } },
        context: {},
        scope: nil,
        attributes: { web: { controller: "HomeController" } }
      ).to_record

      assert_equal "HomeController", record.dig(:attributes, :web, :controller)
      assert_equal "index", record.dig(:attributes, :web, :action)
    end

    def test_record_draft_transforms_whole_data
      draft = draft_with_payload

      draft.transform_record! { |data| data.merge(payload: { token: "[FILTERED]" }) }

      assert_equal({ token: "[FILTERED]" }, draft.fetch(:payload))
    end

    def test_record_draft_transform_is_validated_at_record_boundary
      draft = draft_with_payload

      draft.transform_record! { it.merge(payload: nil) }
      error = assert_raises(TypeError) { draft.to_record }

      assert_equal "record payload must be a Hash", error.message
      assert_nil draft.fetch(:payload)
    end

    def test_record_draft_allows_temporary_non_hash_transform_until_record_boundary
      draft = draft_with_payload

      draft.transform_record! { "bad" }
      error = assert_raises(TypeError) { draft.to_record }

      assert_equal "record must be a normalized Hash", error.message
    end

    def test_record_draft_sections_are_read_only_by_default
      draft = draft_with_context_and_payload

      assert_raises(FrozenError) { draft[:payload][:tags] << "second" }
      assert_raises(FrozenError) { draft[:context][:account][:id] = "changed" }

      draft[:payload] = { tags: ["second"] }

      assert_equal ["second"], draft.dig(:payload, :tags)
    end

    def test_mutable_record_draft_keeps_sections_mutable_until_record_boundary
      draft = Julewire::Core::Records::Draft.build(
        { payload: { tags: ["first"] } },
        context: {},
        scope: nil,
        freeze_sections: false
      )

      draft[:payload][:tags] << "second"
      draft[:payload][:nested] = { value: 1 }
      draft[:payload][:nested][:value] = 2

      record = draft.to_record

      assert_equal %w[first second], record.dig(:payload, :tags)
      assert_equal 2, record.dig(:payload, :nested, :value)
      assert_predicate record.fetch(:payload), :frozen?
    end

    def test_mutable_record_draft_can_merge_missing_optional_sections
      draft = Julewire::Core::Records::Draft.build({}, context: {}, scope: nil, freeze_sections: false)

      draft[:metrics] = { duration_ms: 12.3 }

      assert_equal({ duration_ms: 12.3 }, draft.fetch(:metrics))
    end

    def test_mutable_record_draft_does_not_share_context_or_carry_inputs
      context = { account: { id: "acct-1" } }
      carry = { trace: { id: "trace-1" } }
      draft = Julewire::Core::Records::Draft.build(
        {},
        context: context,
        carry: carry,
        scope: nil,
        freeze_sections: false
      )

      draft[:context][:account][:id] = "mutated"
      draft[:carry][:trace][:id] = "mutated"

      assert_equal "mutated", draft.dig(:context, :account, :id)
      assert_equal "mutated", draft.dig(:carry, :trace, :id)
      assert_equal "acct-1", context.dig(:account, :id)
      assert_equal "trace-1", carry.dig(:trace, :id)
    end

    def test_immutable_record_freezes_owned_draft_sections_in_place
      draft = Julewire::Core::Records::Draft.build(
        { payload: { body: "x" * 4_096 } },
        context: { account: { id: "acct-1" } },
        scope: nil
      )
      draft_context = draft[:context]
      draft_payload = draft[:payload]

      record = draft.to_record

      assert_same draft_context, record[:context]
      assert_equal draft_context, record[:context]
      assert_same draft_payload, record[:payload]
      assert_equal draft_payload, record[:payload]
      assert_predicate record[:context], :frozen?
      assert_predicate record[:payload], :frozen?
    end

    def test_to_record_is_idempotent_after_freezing_draft_data
      draft = Julewire::Core::Records::Draft.build({ payload: { count: 1 } }, context: {}, scope: nil)

      first = draft.to_record
      second = draft.to_record

      assert_same first, second
      assert_equal 1, second.dig(:payload, :count)
    end

    def test_record_draft_moves_ancestors_to_lineage_accessor
      draft = Julewire::Core::Records::Draft.build(
        {
          execution: {
            type: "job",
            id: "job-1",
            ancestors: [{ type: "request", id: "request-1" }],
            ancestors_truncated: true
          }
        },
        context: {},
        scope: nil
      )

      refute draft[:execution].key?(:ancestors)
      refute draft[:execution].key?(:ancestors_truncated)
      assert_equal [{ type: "request", id: "request-1" }], draft.lineage.ancestors
      assert_predicate draft.lineage, :truncated?
    end

    def test_record_draft_updates_lineage_when_execution_section_changes
      draft = Julewire::Core::Records::Draft.build({}, context: {}, scope: nil)

      draft[:execution] = {
        type: "job",
        id: "job-1",
        ancestors: [{ type: "request", id: "request-1" }]
      }

      assert_equal "job-1", draft[:execution][:id]
      assert_equal [{ type: "request", id: "request-1" }], draft.lineage.ancestors

      record = draft.to_record

      refute record[:execution].key?(:ancestors)
      assert_equal [{ type: "request", id: "request-1" }], record.lineage.ancestors
    end

    def test_transform_record_rebuilds_lineage_for_execution_changes
      draft = Julewire::Core::Records::Draft.build({}, context: {}, scope: nil)

      assert_empty draft.lineage.ancestors

      draft.transform_record! do |data|
        data.merge(
          execution: {
            type: "job",
            id: "job-1",
            ancestors: [{ type: "request", id: "request-1" }]
          }
        )
      end

      record = draft.to_record

      refute record[:execution].key?(:ancestors)
      assert_equal [{ type: "request", id: "request-1" }], record.lineage.ancestors
    end

    private

    def draft_with_payload(payload = { token: "secret" })
      Julewire::Core::Records::Draft.build({ payload: payload }, context: {}, scope: nil)
    end

    def draft_with_context_and_payload
      Julewire::Core::Records::Draft.build(
        { payload: { tags: ["first"] } },
        context: { account: { id: "acct-1" } },
        scope: nil
      )
    end
  end
end
