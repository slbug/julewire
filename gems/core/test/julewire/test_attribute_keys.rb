# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestAttributeKeys < Minitest::Test
    cover Julewire::Core::Fields::AttributeKeys
    def test_fields_wraps_compacted_values
      assert_equal(
        { "http.request.method": "GET" },
        Core::Fields::AttributeKeys.fields("http.request.method": "GET", "url.full": nil)
      )
    end

    def test_fields_returns_owned_hash
      fields = { "http.request.method": "GET" }

      refute_same fields, Core::Fields::AttributeKeys.fields(fields)
    end

    def test_fields_accepts_hash_subclasses
      fields = Class.new(Hash).new.merge!("http.request.method": "GET")

      assert_equal(
        { "http.request.method": "GET" },
        Core::Fields::AttributeKeys.fields(fields)
      )
    end

    def test_fields_omits_empty_values
      assert_equal({}, Core::Fields::AttributeKeys.fields(nil))
      assert_equal({}, Core::Fields::AttributeKeys.fields({}))
      assert_equal({}, Core::Fields::AttributeKeys.fields("url.full": nil))
    end

    def test_fields_rejects_non_hash_values
      assert_equal({}, Core::Fields::AttributeKeys.fields([[:custom, "value"]]))
    end

    def test_attribute_keys_document_all_neutral_keys
      docs = File.read(File.expand_path("../../docs/attribute-keys.md", __dir__))
      keys = Core::Fields::AttributeKeys.constants(false).filter_map do |name|
        value = Core::Fields::AttributeKeys.const_get(name)
        value if value.is_a?(Symbol)
      end

      keys.each do |key|
        assert_includes docs, "`#{key}`"
      end
    end
  end
end
