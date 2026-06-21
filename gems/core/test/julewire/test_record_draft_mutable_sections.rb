# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestRecordDraftMutableSections < Minitest::Test
    def test_empty_sections_are_independent
      draft = Core::Records::Draft.build({}, context: {}, carry: {}, scope: nil, freeze_sections: false)

      draft[:context][:request_id] = "request-1"
      draft[:carry][:trace_id] = "trace-1"
      draft[:payload][:processed] = true

      refute_same draft[:context], draft[:carry]
      refute_same draft[:context], draft[:payload]
      assert_equal "request-1", draft.dig(:context, :request_id)
      assert_equal "trace-1", draft.dig(:carry, :trace_id)
      assert draft.dig(:payload, :processed)
    end

    def test_owned_frozen_base_sections_are_not_shared
      context = Core::Fields::FieldSet.frozen_copy(account: { id: "acct-1" })
      attributes = Core::Fields::FieldSet.frozen_copy(web: { controller: "HomeController" })
      draft = Core::Records::Draft.build_pipeline_owned(
        {},
        context: context,
        attributes: attributes,
        scope: nil,
        freeze_sections: false
      )

      draft[:context][:account][:id] = "mutated"
      draft[:attributes][:web][:controller] = "MutatedController"

      assert_equal "mutated", draft.dig(:context, :account, :id)
      assert_equal "MutatedController", draft.dig(:attributes, :web, :controller)
      assert_equal "acct-1", context.dig(:account, :id)
      assert_equal "HomeController", attributes.dig(:web, :controller)
    end
  end
end
