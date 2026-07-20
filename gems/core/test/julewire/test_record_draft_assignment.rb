# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestRecordDraftAssignment < Minitest::Test
    cover Julewire::Core::Records::Draft
    cover "Julewire::Core::Records::Draft::Builder*"

    def test_to_record_finalizes_the_draft
      draft = Julewire::Core::Records::Draft.build(
        { payload: { token: "secret" } },
        context: {},
        scope: nil
      )
      ancestor = { type: "request", id: "request-1" }
      draft[:execution] = { type: "job", id: "job-1", ancestors: [ancestor] }
      record = draft.to_record

      error = assert_raises(FrozenError) do
        draft[:payload] = { token: "[FILTERED]" }
      end

      assert_predicate draft, :frozen?
      assert_match(/frozen/, error.message)
      assert_equal({ token: "secret" }, record.fetch(:payload))
      assert_same record.lineage, draft.lineage
      assert_equal({ type: "job", id: "job-1" }, draft.lineage.root_reference)
      assert_equal [ancestor], draft.lineage.ancestors
    end
  end
end
