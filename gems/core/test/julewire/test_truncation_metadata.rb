# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestTruncationMetadata < Minitest::Test
    cover "Julewire::Core::Serialization::TruncationMetadata"
    cover "Julewire::Core::Serialization::BoundedTraversal.truncation_metadata"

    def test_build_deduplicates_fields_and_keeps_full_limits_by_default
      metadata = truncation_metadata.build(
        %w[message message],
        max_array_items: nil,
        max_depth: 8,
        max_hash_keys: nil,
        max_string_bytes: 10
      )

      assert_string_truncation_metadata metadata,
                                        fields: ["message"],
                                        max_depth: 8,
                                        max_string_bytes: 10
      assert_nil metadata.fetch("limits").fetch("max_array_items")
      assert_nil metadata.fetch("limits").fetch("max_hash_keys")
      refute_predicate metadata, :frozen?
      refute_predicate metadata.fetch("truncated_fields"), :frozen?
    end

    def test_build_accepts_scalar_field_input
      metadata = truncation_metadata.build(
        "message",
        max_array_items: nil,
        max_depth: 8,
        max_hash_keys: nil,
        max_string_bytes: 10
      )

      assert_equal ["message"], metadata.fetch("truncated_fields")
    end

    def test_bounded_traversal_truncation_metadata_uses_default_limits
      traversal = Julewire::Core::Serialization.const_get(:BoundedTraversal, false)
      metadata = traversal.truncation_metadata(["payload"])

      assert_string_truncation_metadata metadata,
                                        fields: ["payload"],
                                        max_array_items: traversal.const_get(:DEFAULT_MAX_ARRAY_ITEMS, false),
                                        max_depth: traversal.const_get(:DEFAULT_MAX_DEPTH, false),
                                        max_hash_keys: traversal.const_get(:DEFAULT_MAX_HASH_KEYS, false),
                                        max_string_bytes: traversal.const_get(:DEFAULT_MAX_STRING_BYTES, false)
    end

    def test_bounded_traversal_truncation_metadata_forwards_symbol_key_style
      traversal = Julewire::Core::Serialization.const_get(:BoundedTraversal, false)

      metadata = traversal.truncation_metadata(["payload"], key_style: :symbol)

      assert_equal %i[truncated truncated_fields limits], metadata.keys
      assert_equal ["payload"], metadata.fetch(:truncated_fields)
      assert_true metadata.fetch(:truncated)
    end

    def test_build_compacts_limits_and_deep_freezes_symbol_metadata
      field = +"message"

      metadata = truncation_metadata.build(
        [field],
        compact_limits: true,
        freeze_values: true,
        key_style: :symbol,
        max_array_items: nil,
        max_depth: 8,
        max_hash_keys: nil,
        max_string_bytes: 10
      )

      assert_predicate metadata, :frozen?
      assert_predicate metadata.fetch(:truncated_fields), :frozen?
      assert_predicate metadata.fetch(:truncated_fields).fetch(0), :frozen?
      assert_predicate metadata.fetch(:limits), :frozen?
      assert_equal({ max_depth: 8, max_string_bytes: 10 }, metadata.fetch(:limits))
    end

    def test_build_deep_freezes_string_metadata
      metadata = truncation_metadata.build(
        [+"message"],
        freeze_values: true,
        key_style: :string,
        max_array_items: nil,
        max_depth: 8,
        max_hash_keys: nil,
        max_string_bytes: 10
      )

      assert_predicate metadata, :frozen?
      assert_predicate metadata.fetch("truncated_fields"), :frozen?
      assert_predicate metadata.fetch("truncated_fields").fetch(0), :frozen?
      assert_predicate metadata.fetch("limits"), :frozen?
    end

    def test_append_field_starts_and_deduplicates_field_lists
      fields = truncation_metadata.append_field(nil, "array_items")

      assert_equal ["array_items"], fields
      assert_same fields, truncation_metadata.append_field(fields, "array_items")
      assert_equal ["array_items"], fields
    end

    def test_valid_accepts_symbol_and_string_metadata
      assert_true truncation_metadata.valid?(symbol_metadata)
      assert_true truncation_metadata.valid?(string_metadata)
      assert_true truncation_metadata.valid?(Class.new(Hash).new.merge!(symbol_metadata))
      assert_true truncation_metadata.valid?(symbol_metadata.merge(truncated_fields: Class.new(Array).new(["message"])))
      assert_true truncation_metadata.valid?(symbol_metadata.merge(limits: Class.new(Hash).new.merge!(max_depth: 8)))
    end

    def test_valid_rejects_mixed_or_extra_top_level_keys
      assert_false truncation_metadata.valid?(Object.new)
      assert_false truncation_metadata.valid?(
        {
          truncated: true,
          "truncated_fields" => ["message"],
          limits: { max_depth: 8 }
        }
      )
      assert_false truncation_metadata.valid?(symbol_metadata.merge(extra: true))
    end

    def test_valid_rejects_bad_truncated_field_shapes
      assert_false truncation_metadata.valid?(symbol_metadata.merge(truncated: false))
      assert_false truncation_metadata.valid?(symbol_metadata.merge(truncated: 1))
      assert_false truncation_metadata.valid?(symbol_metadata.merge(truncated_fields: "message"))
      assert_false truncation_metadata.valid?(symbol_metadata.merge(truncated_fields: [Object.new]))
      assert_false truncation_metadata.valid?(symbol_metadata.merge(truncated_fields: [:message]))
      assert_false truncation_metadata.valid?(symbol_metadata.merge(truncated_fields: ["ok", Object.new]))
      assert_false truncation_metadata.valid?(symbol_metadata.merge(truncated_fields: %w[one two]), max_fields: 1)
      assert_true truncation_metadata.valid?(symbol_metadata.merge(truncated_fields: %w[one two]), max_fields: 2)
    end

    def test_valid_rejects_bad_limit_shapes
      assert_false truncation_metadata.valid?(symbol_metadata.merge(limits: "limits"))
      assert_false truncation_metadata.valid?(symbol_metadata.merge(limits: { unknown: 1 }))
      assert_false truncation_metadata.valid?(symbol_metadata.merge(limits: { max_depth: "8" }))
      assert_false truncation_metadata.valid?(symbol_metadata.merge(limits: { max_depth: 8, unknown: 1 }))
      assert_false truncation_metadata.valid?(symbol_metadata.merge(limits: { max_depth: 8, max_hash_keys: "1" }))
      assert_false truncation_metadata.valid?(string_metadata.merge("limits" => { max_depth: 8 }))
    end

    def test_copy_defaults_to_symbol_keys_without_freezing_or_aliasing_fields
      field = +"message"
      source = symbol_metadata.merge(truncated_fields: [field])

      metadata = truncation_metadata.copy(source, freeze_values: false)

      assert_equal %i[truncated truncated_fields limits], metadata.keys
      assert_equal [field], metadata.fetch(:truncated_fields)
      refute_same source.fetch(:truncated_fields), metadata.fetch(:truncated_fields)
      refute_same field, metadata.fetch(:truncated_fields).fetch(0)
      refute_predicate metadata, :frozen?
      refute_predicate metadata.fetch(:truncated_fields), :frozen?
      refute_predicate metadata.fetch(:limits), :frozen?
    end

    def test_copy_converts_symbol_metadata_to_string_key_style
      metadata = truncation_metadata.copy(symbol_metadata, key_style: :string, freeze_values: false)

      assert_equal %w[truncated truncated_fields limits], metadata.keys
      assert_true metadata.fetch("truncated")
      assert_equal ["message"], metadata.fetch("truncated_fields")
      assert_equal(
        {
          "max_array_items" => nil,
          "max_depth" => 8,
          "max_hash_keys" => nil,
          "max_string_bytes" => 10
        },
        metadata.fetch("limits")
      )
    end

    def test_copy_converts_string_metadata_to_frozen_symbol_key_style
      metadata = truncation_metadata.copy(string_metadata, key_style: :symbol, freeze_values: true)

      assert_equal %i[truncated truncated_fields limits], metadata.keys
      assert_true metadata.fetch(:truncated)
      assert_equal ["message"], metadata.fetch(:truncated_fields)
      assert_equal(
        {
          max_array_items: nil,
          max_depth: 8,
          max_hash_keys: nil,
          max_string_bytes: 10
        },
        metadata.fetch(:limits)
      )
      assert_predicate metadata, :frozen?
      assert_predicate metadata.fetch(:truncated_fields), :frozen?
      assert_predicate metadata.fetch(:truncated_fields).fetch(0), :frozen?
      assert_predicate metadata.fetch(:limits), :frozen?
    end

    def test_copy_preserves_sparse_limits_and_continues_after_absent_keys
      source = symbol_metadata.merge(
        limits: {
          max_depth: 8,
          max_string_bytes: 10
        }
      )

      metadata = truncation_metadata.copy(source, key_style: :string, freeze_values: false)

      assert_equal(
        {
          "max_depth" => 8,
          "max_string_bytes" => 10
        },
        metadata.fetch("limits")
      )
    end

    private

    def truncation_metadata
      Julewire::Core::Serialization.const_get(:TruncationMetadata)
    end

    def symbol_metadata
      {
        truncated: true,
        truncated_fields: ["message"],
        limits: {
          max_array_items: nil,
          max_depth: 8,
          max_hash_keys: nil,
          max_string_bytes: 10
        }
      }
    end

    def string_metadata
      {
        "truncated" => true,
        "truncated_fields" => ["message"],
        "limits" => {
          "max_array_items" => nil,
          "max_depth" => 8,
          "max_hash_keys" => nil,
          "max_string_bytes" => 10
        }
      }
    end
  end
end
