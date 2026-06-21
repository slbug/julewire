# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestParameterFilterPlan < Minitest::Test
    cover Julewire::Rails::ParameterFilterPlan

    def test_build_returns_nil_for_compound_filters
      assert_nil Julewire::Rails::ParameterFilterPlan.build([/token/])
      assert_nil Julewire::Rails::ParameterFilterPlan.build([proc {}])
    end

    def test_filtered_field_keys_include_only_relevant_record_sections
      simple = Julewire::Rails::ParameterFilterPlan.build(%i[token])
      deep = Julewire::Rails::ParameterFilterPlan.build(["payload.password"])

      assert_includes simple.filtered_field_keys, :payload
      assert_includes simple.filtered_field_keys, :context
      assert_includes simple.filtered_field_keys, :attributes
      assert_equal [:payload], deep.filtered_field_keys
    end

    def test_filter_value_duplicates_only_changed_containers
      plan = Julewire::Rails::ParameterFilterPlan.build(%i[token])
      clean = { visible: { nested: "ok" } }
      dirty = { visible: "ok", nested: [{ token: "secret" }] }

      assert_same clean, plan.filter_value(clean)

      filtered = plan.filter_value(dirty)

      refute_same dirty, filtered
      assert_equal "[FILTERED]", filtered.dig(:nested, 0, :token)
      assert_equal "ok", filtered.fetch(:visible)
    end
  end
end
