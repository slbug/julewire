# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestRecordNormalizationBounds < Minitest::Test
    cover Julewire::Core::Records::Record
    cover Julewire::Core::Serialization::ValueCopy

    def test_record_draft_build_bounds_deep_payload_normalization
      draft = Julewire::Core::Records::Draft.build(
        { payload: { nested: deep_hash(Julewire::Core::NORMALIZATION_MAX_DEPTH + 8) } },
        context: {},
        scope: nil
      )

      assert deep_value_contains?(draft.fetch(:payload), Julewire::Core::Serialization::Serializer::MAX_DEPTH_VALUE)
    end

    def test_record_draft_build_bounds_payload_array_items
      draft = Julewire::Core::Records::Draft.build(
        { payload: { ids: Array.new(1_005) { it } } },
        context: {},
        scope: nil
      )

      ids = draft.dig(:payload, :ids)

      assert_equal 1_001, ids.length
      assert_equal 999, ids.fetch(999)
      assert_symbol_truncation_metadata ids.fetch(1_000).fetch(:_julewire_truncation),
                                        fields: ["array_items"],
                                        max_array_items: 1_000
      assert_symbol_truncation_metadata draft.dig(:payload, :_julewire_truncation),
                                        fields: ["ids"],
                                        max_array_items: 1_000
    end

    def test_record_draft_build_bounds_payload_hash_keys
      payload = {}
      1_005.times { payload["key_#{it}"] = it }

      draft = Julewire::Core::Records::Draft.build({ payload: payload }, context: {}, scope: nil)
      copied = draft.fetch(:payload)

      assert_equal 1_001, copied.length
      assert_equal 999, copied.fetch(key_symbol(999))
      assert_symbol_truncation_metadata copied.fetch(:_julewire_truncation),
                                        fields: ["hash_keys"],
                                        max_hash_keys: 1_000
      refute copied.key?(key_symbol(1_000))
    end

    def test_record_draft_build_bounds_payload_string_bytes
      limit = Julewire::Core::Serialization::Serializer::DEFAULT_MAX_STRING_BYTES
      value = "a" * (limit + 5)

      draft = Julewire::Core::Records::Draft.build(
        { payload: { message: value } },
        context: {},
        scope: nil
      )

      assert_equal "#{"a" * limit}...[Truncated]", draft.dig(:payload, :message)
      metadata = draft.dig(:payload, :_julewire_truncation)

      assert_symbol_truncation_metadata metadata,
                                        fields: ["message"],
                                        max_string_bytes: limit
      assert_predicate metadata, :frozen?
      assert_predicate metadata.fetch(:truncated_fields), :frozen?
      assert_predicate metadata.fetch(:limits), :frozen?
    end

    def test_value_copy_hash_key_limit_counts_input_entries_before_symbolized_key_collisions
      value = { "same" => 1, :same => 2, "other" => 3 }

      copied = Julewire::Core::Serialization::ValueCopy.call(value, max_hash_keys: 2, symbolize_keys: true)

      assert_equal 2, copied.fetch(:same)
      assert_symbol_truncation_metadata copied.fetch(:_julewire_truncation),
                                        fields: ["hash_keys"],
                                        max_hash_keys: 2
      refute copied.key?(:other)
    end

    def test_value_copy_array_limit_counts_visited_items_before_copied_empty_omission
      copied = Julewire::Core::Serialization::ValueCopy.call(
        [[nil], "later"],
        compact_empty: true,
        max_array_items: 1
      )

      assert_equal 1, copied.length
      assert_symbol_truncation_metadata copied.fetch(0).fetch(:_julewire_truncation),
                                        fields: ["array_items"],
                                        max_array_items: 1
    end

    def test_value_copy_array_nested_truncation_uses_value_label
      copied = Julewire::Core::Serialization::ValueCopy.call(
        ["abcdef"],
        max_array_items: 10,
        max_string_bytes: 3
      )

      assert_equal "abc...[Truncated]", copied.fetch(0)
      assert_symbol_truncation_metadata copied.fetch(1).fetch(:_julewire_truncation),
                                        fields: ["array_item_values"],
                                        max_array_items: 10,
                                        max_string_bytes: 3
    end

    def test_value_copy_hash_limit_counts_copied_empty_entries_before_omission
      copied = Julewire::Core::Serialization::ValueCopy.call(
        { drop: [nil], later: "unvisited" },
        compact_empty: true,
        max_hash_keys: 1
      )

      assert_equal [:_julewire_truncation], copied.keys
      assert_symbol_truncation_metadata copied.fetch(:_julewire_truncation),
                                        fields: ["hash_keys"],
                                        max_hash_keys: 1
    end

    def test_value_copy_hash_limit_counts_raw_empty_entries_before_omission
      copied = Julewire::Core::Serialization::ValueCopy.call(
        { drop: nil, later: "unvisited" },
        compact_empty: true,
        max_hash_keys: 1
      )

      assert_equal [:_julewire_truncation], copied.keys
      assert_symbol_truncation_metadata copied.fetch(:_julewire_truncation),
                                        fields: ["hash_keys"],
                                        max_hash_keys: 1
    end

    def test_value_copy_array_limit_counts_raw_empty_entries_before_omission
      copied = Julewire::Core::Serialization::ValueCopy.call(
        [nil, "unvisited"],
        compact_empty: true,
        max_array_items: 1
      )

      assert_equal 1, copied.length
      assert_symbol_truncation_metadata copied.fetch(0).fetch(:_julewire_truncation),
                                        fields: ["array_items"],
                                        max_array_items: 1
    end

    def test_value_copy_truncation_metadata_omits_unconfigured_optional_limits
      copied = Julewire::Core::Serialization::ValueCopy.call(
        { message: "abcdef" },
        max_string_bytes: 3
      )

      limits = copied.dig(:_julewire_truncation, :limits)

      assert_equal(
        {
          max_depth: Julewire::Core::NORMALIZATION_MAX_DEPTH,
          max_string_bytes: 3
        },
        limits
      )
    end

    def test_value_copy_truncates_string_keys_before_symbolizing
      copied = Julewire::Core::Serialization::ValueCopy.call(
        { "abcdef" => 1 },
        max_string_bytes: 3,
        symbolize_keys: true
      )

      assert_equal 1, copied.fetch(:"abc...[Truncated]")
      assert_symbol_truncation_metadata copied.fetch(:_julewire_truncation),
                                        fields: ["abc...[Truncated]"],
                                        max_string_bytes: 3
    end

    def test_record_finalization_bounds_deep_owned_mutation
      draft = Julewire::Core::Records::Draft.from_normalized_hash(normalized_record, freeze_sections: false)
      draft[:payload] = { nested: deep_hash(Julewire::Core::NORMALIZATION_MAX_DEPTH + 8) }

      record = draft.to_record

      assert deep_value_contains?(record.fetch(:payload), Julewire::Core::Serialization::Serializer::MAX_DEPTH_VALUE)
    end

    private

    def deep_hash(depth)
      depth.times.reduce("leaf") { |value, index| { "level_#{index}": value } }
    end

    def key_symbol(index)
      :"key_#{index}"
    end

    def deep_value_contains?(value, expected)
      return true if value == expected
      return value.any? { deep_value_contains?(it, expected) } if value.is_a?(Array)
      return value.any? { |_, item| deep_value_contains?(item, expected) } if value.is_a?(Hash)

      false
    end
  end
end
