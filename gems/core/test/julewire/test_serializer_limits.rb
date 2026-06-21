# frozen_string_literal: true

require "test_helper"
require "bigdecimal"

module Julewire
  class TestSerializerLimits < Minitest::Test
    cover "Julewire::Core::Serialization::BoundedTraversal"
    cover Julewire::Core::Serialization::Serializer

    METADATA_KEY = Julewire::Core::Serialization::Serializer::TRUNCATION_METADATA_KEY

    def test_serializer_truncates_long_strings_and_marks_parent_field
      serialized = Julewire::Core::Serialization::Serializer.call({ message: "abcdef" }, max_string_bytes: 3)

      assert_equal "abc...[Truncated]", serialized.fetch("message")
      assert_string_truncation_metadata serialized.fetch(METADATA_KEY),
                                        fields: ["message"],
                                        max_string_bytes: 3
    end

    def test_serializer_truncates_arrays_and_marks_parent_field
      serialized = Julewire::Core::Serialization::Serializer.call({ items: [1, 2, 3] }, max_array_items: 2)
      items = serialized.fetch("items")

      assert_equal [1, 2], items.first(2)
      assert_string_truncation_metadata items.fetch(2).fetch(METADATA_KEY),
                                        fields: ["array_items"],
                                        max_array_items: 2
      assert_string_truncation_metadata serialized.fetch(METADATA_KEY),
                                        fields: ["items"],
                                        max_array_items: 2
    end

    def test_serializer_truncates_hash_keys_and_marks_hash
      serialized = Julewire::Core::Serialization::Serializer.call({ a: 1, b: 2, c: 3 }, max_hash_keys: 2)

      assert_equal 1, serialized.fetch("a")
      assert_equal 2, serialized.fetch("b")
      refute_includes serialized, "c"
      assert_string_truncation_metadata serialized.fetch(METADATA_KEY),
                                        fields: ["hash_keys"],
                                        max_hash_keys: 2
    end

    def test_serializer_can_compact_empty_values_during_serialization
      serialized = Julewire::Core::Serialization::Serializer.call(compactable_value, compact_empty: true)

      assert_equal(
        {
          "false_value" => false,
          "zero" => 0,
          "empty_string" => "",
          "nested" => { "kept" => { "value" => 1 } },
          "array" => [{ "keep" => true }]
        },
        serialized
      )
    end

    def test_serializer_compact_empty_skips_raw_empty_containers_before_walking
      broken_empty_hash = Class.new(Hash) do
        def each
          raise "should not walk omitted empty hash"
        end
      end.new

      serialized = Julewire::Core::Serialization::Serializer.call(
        {
          keep: "ok",
          skipped: broken_empty_hash,
          array: [nil, {}, [], "ok"]
        },
        compact_empty: true
      )

      assert_equal({ "keep" => "ok", "array" => ["ok"] }, serialized)
    end

    def test_serializer_compact_empty_preserves_default_serializer_shape_when_disabled
      serialized = Julewire::Core::Serialization::Serializer.call({ nil_value: nil, empty_hash: {}, empty_array: [] })

      assert_equal({ "nil_value" => nil, "empty_hash" => {}, "empty_array" => [] }, serialized)
    end

    def test_serializer_compact_empty_counts_raw_entries_before_compaction
      serialized = Julewire::Core::Serialization::Serializer.call(
        {
          skipped: nil,
          empty: {},
          first: 1,
          second: 2,
          third: 3
        },
        compact_empty: true,
        max_hash_keys: 3
      )

      assert_equal 1, serialized.fetch("first")
      refute_includes serialized, "second"
      refute_includes serialized, "third"
      assert_string_truncation_metadata serialized.fetch(METADATA_KEY),
                                        fields: ["hash_keys"],
                                        max_hash_keys: 3
    end

    def test_serializer_marks_max_depth_hash_pruning
      serialized = Julewire::Core::Serialization::Serializer.call({ a: { b: { c: 1 } } }, max_depth: 2)

      assert_equal "[MaxDepth]", serialized.dig("a", "b")
      assert_string_truncation_metadata serialized.fetch("a").fetch(METADATA_KEY),
                                        fields: ["b"],
                                        max_depth: 2
      assert_string_truncation_metadata serialized.fetch(METADATA_KEY),
                                        fields: ["a"],
                                        max_depth: 2
    end

    def test_serializer_marks_max_depth_array_pruning
      serialized = Julewire::Core::Serialization::Serializer.call({ items: [[1]] }, max_depth: 2)
      items = serialized.fetch("items")

      assert_equal "[MaxDepth]", items.first
      assert_string_truncation_metadata items.fetch(1).fetch(METADATA_KEY),
                                        fields: ["array_items"],
                                        max_depth: 2
      assert_string_truncation_metadata serialized.fetch(METADATA_KEY),
                                        fields: ["items"],
                                        max_depth: 2
    end

    def test_serializer_marks_top_level_array_depth_pruning
      serialized = Julewire::Core::Serialization::Serializer.call([[1]], max_depth: 1)

      assert_equal "[MaxDepth]", serialized.first
      assert_string_truncation_metadata serialized.fetch(1).fetch(METADATA_KEY),
                                        fields: ["array_items"],
                                        max_depth: 1
    end

    def test_serializer_marks_compact_array_item_limit
      serialized = Julewire::Core::Serialization::Serializer.call(
        { items: [1, 2, 3] },
        compact_empty: true,
        max_array_items: 2
      )

      items = serialized.fetch("items")

      assert_equal [1, 2], items.first(2)
      assert_string_truncation_metadata items.fetch(2).fetch(METADATA_KEY),
                                        fields: ["array_items"],
                                        max_array_items: 2
      assert_string_truncation_metadata serialized.fetch(METADATA_KEY),
                                        fields: ["items"],
                                        max_array_items: 2
    end

    def test_serializer_truncates_on_byte_boundary_without_invalid_utf8
      serialized = Julewire::Core::Serialization::Serializer.call({ message: "ééé" }, max_string_bytes: 3)
      message = serialized.fetch("message")

      assert_predicate message, :valid_encoding?
      assert_equal "é?...[Truncated]", message
    end

    def test_serializer_keeps_strings_at_exact_byte_limit_without_metadata
      serialized = Julewire::Core::Serialization::Serializer.call({ message: "abc" }, max_string_bytes: 3)

      assert_equal "abc", serialized.fetch("message")
      refute_includes serialized, METADATA_KEY
    end

    def test_serializer_truncates_big_decimal_strings
      serialized = Julewire::Core::Serialization::Serializer.call({ decimal: BigDecimal("123456789.12345") },
                                                                  max_string_bytes: 6)

      assert_equal "123456...[Truncated]", serialized.fetch("decimal")
      assert_string_truncation_metadata serialized.fetch(METADATA_KEY),
                                        fields: ["decimal"],
                                        max_string_bytes: 6
    end

    def test_serializer_does_not_treat_user_truncation_like_values_as_metadata
      serialized = Julewire::Core::Serialization::Serializer.call(
        {
          message: "already...[Truncated]",
          nested: { message: "ok" }
        }
      )

      refute_includes serialized, METADATA_KEY
      assert_equal "already...[Truncated]", serialized.fetch("message")
      assert_equal "ok", serialized.fetch("nested").fetch("message")
    end

    def test_serializer_truncation_key_is_reserved_by_contract
      serialized = Julewire::Core::Serialization::Serializer.call(
        {
          METADATA_KEY => "ok",
          message: "abcdef"
        },
        max_string_bytes: 3
      )

      assert_string_truncation_metadata serialized.fetch(METADATA_KEY),
                                        fields: ["message"],
                                        max_string_bytes: 3
    end

    def test_serializer_rejects_negative_limits
      %i[max_string_bytes max_array_items max_hash_keys max_backtrace_lines].each do |limit_name|
        error = assert_raises(ArgumentError) do
          Julewire::Core::Serialization::Serializer.call({ message: "hello" }, **{ limit_name => -1 })
        end

        assert_equal "#{limit_name} must be a non-negative Integer", error.message
      end
    end

    def test_serializer_requires_positive_max_depth
      [0, -1].each do |max_depth|
        error = assert_raises(ArgumentError) do
          Julewire::Core::Serialization::Serializer.call("hello", max_depth: max_depth)
        end

        assert_equal "max_depth must be a positive Integer", error.message
      end
    end

    def test_serializer_rejects_non_integer_limits
      error = assert_raises(ArgumentError) do
        Julewire::Core::Serialization::Serializer.call({ message: "hello" }, max_depth: 1.5)
      end

      assert_equal "max_depth must be a positive Integer", error.message
    end

    private

    def compactable_value
      {
        nil_value: nil,
        empty_hash: {},
        empty_array: [],
        false_value: false,
        zero: 0,
        empty_string: "",
        nested: {
          removed: { child: nil },
          kept: { value: 1 }
        },
        array: [nil, {}, [], { removed: nil }, { keep: true }]
      }
    end
  end

  class TestSerializerConstructorAndExceptionLimits < Minitest::Test
    cover Julewire::Core::Serialization::Serializer

    METADATA_KEY = Julewire::Core::Serialization::Serializer::TRUNCATION_METADATA_KEY

    def test_serializer_instance_preserves_default_shape_when_compaction_not_requested
      serialized = Julewire::Core::Serialization::Serializer.new.serialize(
        { nil_value: nil, empty_hash: {}, empty_array: [] }
      )

      assert_equal({ "nil_value" => nil, "empty_hash" => {}, "empty_array" => [] }, serialized)
    end

    def test_serializer_counts_exception_shape_against_depth_limit
      error = RuntimeError.new("boom")

      serialized = Julewire::Core::Serialization::Serializer.call(error, max_depth: 2)
      metadata = serialized.fetch(METADATA_KEY)

      assert_equal "[MaxDepth]", serialized.fetch("class")
      assert_equal "[MaxDepth]", serialized.fetch("message")
      assert metadata.fetch("truncated")
      assert_equal %w[class message], metadata.fetch("truncated_fields")
      assert_equal 2, metadata.dig("limits", "max_depth")
    end
  end
end
