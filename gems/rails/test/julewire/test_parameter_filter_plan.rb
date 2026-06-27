# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestParameterFilterPlan < Minitest::Test
    cover Julewire::Rails::ParameterFilterPlan
    cover "Julewire::Rails::ParameterFilterPlan#simple_filter_pattern"
    cover "Julewire::Rails::ParameterFilterPlan.build"
    def test_build_returns_nil_for_compound_filters
      assert_nil Julewire::Rails::ParameterFilterPlan.build([])
      assert_nil Julewire::Rails::ParameterFilterPlan.build([/token/])
      assert_nil Julewire::Rails::ParameterFilterPlan.build([:token, /password/])
      assert_nil Julewire::Rails::ParameterFilterPlan.build([proc {}])
      assert_nil Julewire::Rails::ParameterFilterPlan.build(["payload.password"])
      assert_nil Julewire::Rails::ParameterFilterPlan.build([:token, "payload.password"])
    end

    def test_build_accepts_scalar_filter
      plan = Julewire::Rails::ParameterFilterPlan.build(:token)
      filtered = plan.filter_value({ token: "secret", visible: "ok" })

      assert_equal "[FILTERED]", filtered.fetch(:token)
      assert_equal "ok", filtered.fetch(:visible)
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

    def test_filter_value_filters_string_symbol_nil_and_object_keys
      object_key = Object.new
      object_key.define_singleton_method(:to_s) { "token_object" }
      plan = Julewire::Rails::ParameterFilterPlan.build(%i[token])
      input = {
        "token" => "a",
        token: "b",
        nil => "plain",
        object_key => "c",
        visible: "ok"
      }
      filtered = plan.filter_value(input)

      assert_equal "[FILTERED]", filtered.fetch("token")
      assert_equal "[FILTERED]", filtered.fetch(:token)
      assert_equal "[FILTERED]", filtered.fetch(object_key)
      assert_equal "plain", filtered.fetch(nil)
      assert_equal "ok", filtered.fetch(:visible)
    end

    def test_simple_filters_are_literal_patterns
      plan = Julewire::Rails::ParameterFilterPlan.build(["token+"])
      filtered = plan.filter_value({ "token+" => "a", "tokenn" => "b" })

      assert_equal "[FILTERED]", filtered.fetch("token+")
      assert_equal "b", filtered.fetch("tokenn")
    end

    def test_simple_filters_are_case_insensitive_alternatives
      plan = Julewire::Rails::ParameterFilterPlan.build(%i[token password])
      filtered = plan.filter_value(
        "TOKEN" => "a",
        "password" => "b",
        "visible" => "ok"
      )

      assert_equal "[FILTERED]", filtered.fetch("TOKEN")
      assert_equal "[FILTERED]", filtered.fetch("password")
      assert_equal "ok", filtered.fetch("visible")
    end

    def test_filter_value_filters_hash_and_array_subclasses
      hash = Class.new(Hash).new
      hash[:token] = "secret"
      array = Class.new(Array).new([{ token: "nested" }])
      plan = Julewire::Rails::ParameterFilterPlan.build([:token])

      assert_equal "[FILTERED]", plan.filter_value(hash).fetch(:token)
      assert_equal "[FILTERED]", plan.filter_value(array).fetch(0).fetch(:token)
    end

    def test_filter_value_filters_arrays_copy_on_write
      plan = Julewire::Rails::ParameterFilterPlan.build([:token])
      clean = [{ visible: "ok" }]
      dirty = [{ visible: "ok" }, { token: "secret" }]

      assert_same clean, plan.filter_value(clean)

      filtered = plan.filter_value(dirty)

      refute_same dirty, filtered
      assert_equal "secret", dirty.fetch(1).fetch(:token)
      assert_equal "[FILTERED]", filtered.fetch(1).fetch(:token)
      assert_same dirty.fetch(0), filtered.fetch(0)
    end
  end
end
