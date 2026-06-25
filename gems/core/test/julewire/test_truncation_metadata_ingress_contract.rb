# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestTruncationMetadataIngressContract < Minitest::Test
    cover Julewire::Core::Serialization::ValueCopy

    def test_rejects_reserved_truncation_metadata_key_at_symbol_ingress
      error = assert_raises(ArgumentError) do
        Julewire::Core::Fields::FieldSet.deep_symbolize_keys("_julewire_truncation" => { "user" => true })
      end

      assert_equal "_julewire_truncation is reserved for Julewire truncation metadata", error.message
    end

    def test_rejects_reserved_truncation_metadata_symbol_key_without_metadata_shape
      error = assert_raises(ArgumentError) do
        Julewire::Core::Serialization::ValueCopy.call(
          { _julewire_truncation: "user", other: "value" },
          max_hash_keys: 1,
          symbolize_keys: false
        )
      end

      assert_equal "_julewire_truncation is reserved for Julewire truncation metadata", error.message
    end

    def test_rejects_string_truncation_metadata_marker_without_symbolizing_ingress
      error = assert_raises(ArgumentError) do
        Julewire::Core::Serialization::ValueCopy.call(
          { "_julewire_truncation" => string_truncation_metadata },
          symbolize_keys: false
        )
      end

      assert_equal "_julewire_truncation is reserved for Julewire truncation metadata", error.message
    end

    def test_preserves_symbol_truncation_metadata_marker_for_owned_metadata
      copied = Julewire::Core::Serialization::ValueCopy.call(
        { _julewire_truncation: symbol_truncation_metadata },
        symbolize_keys: false
      )

      assert_equal [:_julewire_truncation], copied.keys
      assert_symbol_truncation_metadata copied.fetch(:_julewire_truncation),
                                        fields: ["field"],
                                        max_depth: 20,
                                        max_string_bytes: 10
    end

    def test_symbolizes_string_truncation_metadata_marker_only_on_ingress
      copied = Julewire::Core::Serialization::ValueCopy.call(
        { "_julewire_truncation" => string_truncation_metadata },
        symbolize_keys: true
      )

      assert_equal [:_julewire_truncation], copied.keys
      assert_symbol_truncation_metadata copied.fetch(:_julewire_truncation),
                                        fields: ["field"],
                                        max_depth: 20,
                                        max_string_bytes: 10
    end

    private

    def string_truncation_metadata
      {
        "truncated" => true,
        "truncated_fields" => ["field"],
        "limits" => {
          "max_array_items" => nil,
          "max_depth" => 20,
          "max_hash_keys" => nil,
          "max_string_bytes" => 10
        }
      }
    end

    def symbol_truncation_metadata
      {
        truncated: true,
        truncated_fields: ["field"],
        limits: {
          max_array_items: nil,
          max_depth: 20,
          max_hash_keys: nil,
          max_string_bytes: 10
        }
      }
    end
  end
end
