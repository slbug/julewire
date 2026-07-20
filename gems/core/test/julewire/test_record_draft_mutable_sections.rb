# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestRecordDraftMutableSections < Minitest::Test
    cover Julewire::Core::Records::Draft
    cover "Julewire::Core::Records::Draft::Builder*"

    def test_empty_sections_are_independent
      draft = Core::Records::Draft.build({}, context: {}, carry: {}, scope: nil)

      draft[:context][:request_id] = "request-1"
      draft[:carry][:trace_id] = "trace-1"
      draft[:payload][:processed] = true

      refute_same draft[:context], draft[:carry]
      refute_same draft[:context], draft[:payload]
      assert_equal "request-1", draft.dig(:context, :request_id)
      assert_equal "trace-1", draft.dig(:carry, :trace_id)
      assert_true draft.dig(:payload, :processed)
    end

    def test_owned_frozen_base_sections_are_not_shared
      context = Core::Fields::FieldSet.frozen_copy(account: { id: "acct-1" })
      attributes = Core::Fields::FieldSet.frozen_copy(web: { controller: "HomeController" })
      draft = Core::Records::Draft.build_pipeline_owned(
        {},
        context: context,
        attributes: attributes,
        scope: nil
      )

      draft[:context][:account][:id] = "mutated"
      draft[:attributes][:web][:controller] = "MutatedController"

      assert_equal "mutated", draft.dig(:context, :account, :id)
      assert_equal "MutatedController", draft.dig(:attributes, :web, :controller)
      assert_equal "acct-1", context.dig(:account, :id)
      assert_equal "HomeController", attributes.dig(:web, :controller)
    end

    def test_owned_mutable_base_sections_are_copied_into_the_draft
      context = { account: { id: "acct-1" } }
      draft = Core::Records::Draft.build_pipeline_owned(
        {},
        context: context,
        scope: nil
      )

      refute_same context, draft[:context]
      refute_predicate draft[:context], :frozen?

      context[:account][:id] = "mutated"

      assert_equal "acct-1", draft.dig(:context, :account, :id)
    end

    def test_unowned_frozen_base_sections_are_copied
      context = Core::Fields::FieldSet.frozen_copy(account: { id: "acct-1" })
      draft = Core::Records::Draft.build(
        {},
        context: context,
        scope: nil
      )

      refute_same context, draft[:context]
      refute_predicate draft[:context], :frozen?
      assert_equal({ account: { id: "acct-1" } }, draft[:context])
    end

    def test_owned_frozen_hash_subclass_base_sections_are_copied
      context = Class.new(Hash).new
      context[:account] = { id: "acct-1" }
      context.freeze
      draft = Core::Records::Draft.build_pipeline_owned(
        {},
        context: context,
        scope: nil
      )

      refute_same context, draft[:context]
      refute_predicate draft[:context], :frozen?
    end
  end
end
