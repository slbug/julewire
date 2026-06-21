# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestRecordDraftAssignment < Minitest::Test
    def test_direct_assignment_copies_after_to_record
      draft = Julewire::Core::Records::Draft.build(
        { payload: { token: "secret" } },
        context: {},
        scope: nil,
        freeze_sections: false
      )
      original = draft.to_record

      draft[:payload] = { token: "[FILTERED]" }

      assert_equal({ token: "secret" }, original.fetch(:payload))
      assert_equal({ token: "[FILTERED]" }, draft.to_record.fetch(:payload))
    end
  end
end
