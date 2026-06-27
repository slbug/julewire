# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestBoundedTransform < Minitest::Test
    cover Julewire::Core::Serialization::BoundedTransform
    cover "Julewire::Core::Serialization::BoundedTraversal#walk_value"
    cover "Julewire::Core::Serialization::BoundedTraversal#walk_full_hash"
    cover "Julewire::Core::Serialization::BoundedTraversal#walk_full_array"
    cover "Julewire::Core::Serialization::BoundedTraversal#walk_compact_hash"
    cover "Julewire::Core::Serialization::BoundedTraversal#walk_compact_array"
    cover "Julewire::Core::Serialization::BoundedTraversal#initialize"
    cover "Julewire::Core::Serialization::BoundedTraversal#walk_container"
    cover "Julewire::Core::Serialization::BoundedTraversal#hash_like?"
    cover "Julewire::Core::Serialization::BoundedTraversal#string_value"
    cover "Julewire::Core::Serialization::BoundedTraversal#copy_string"
    def test_default_transform_copies_clean_values_without_truncation_metadata
      value = { payload: { name: "ok" }, items: [1, 2] }

      result = Julewire::Core::Serialization::BoundedTransform.call(value)

      assert_equal value, result
      refute_same value, result
      assert_false result.key?(:_julewire_truncation)
    end

    def test_transform_block_receives_key_path_original_and_depth
      calls = []
      value = { payload: { secret: "abc" } }

      result = Julewire::Core::Serialization::BoundedTransform.call(value) do |item, key:, path:, original:, depth:|
        calls << [item, key, path, original.equal?(value), depth]
        key == :secret ? "[FILTERED]" : Julewire::Core::Serialization::BoundedTransform::CONTINUE
      end

      assert_equal "[FILTERED]", result.dig(:payload, :secret)
      assert_includes calls, ["abc", :secret, "payload.secret", true, 2]
    end

    def test_transform_block_receives_parent_path_for_array_children
      paths = []

      Julewire::Core::Serialization::BoundedTransform.call({ items: ["abc"] }) do |item, path:, **|
        paths << path if item == "abc"
        Julewire::Core::Serialization::BoundedTransform::CONTINUE
      end

      assert_equal ["items"], paths
    end

    def test_path_tracking_can_be_disabled
      paths = []
      value = { payload: { secret: "abc" } }

      Julewire::Core::Serialization::BoundedTransform.call(value, track_paths: false) do |_item, key:, path:, **|
        paths << path if key == :secret
        Julewire::Core::Serialization::BoundedTransform::CONTINUE
      end

      assert_equal [nil], paths
    end

    def test_path_tracking_option_does_not_do_work_without_transform_block
      key = Object.new
      key.define_singleton_method(:to_s) { raise "path should not be built" }

      result = Julewire::Core::Serialization::BoundedTransform.call({ key => "ok" }, track_paths: true)

      assert_equal "ok", result.fetch(key)
    end

    def test_limits_hash_keys_arrays_depth_and_strings
      result = Julewire::Core::Serialization::BoundedTransform.call(
        {
          deep: { nested: { value: "hidden" } },
          long: "abcdef",
          list: %w[abcdef extra]
        },
        max_depth: 3,
        max_string_bytes: 3,
        max_array_items: 1,
        max_hash_keys: 5
      )

      assert_equal "[MaxDepth]", result.dig(:deep, :nested, :value)
      assert_equal "abc...[Truncated]", result[:long]
      assert_equal "abc...[Truncated]", result.dig(:list, 0)
      assert_true result.dig(:list, 1, :_julewire_truncation, :truncated)
      assert_true result.dig(:_julewire_truncation, :truncated)
    end

    def test_handles_hash_array_and_string_subclasses
      hash = Class.new(Hash).new.merge!(payload: Class.new(Hash).new.merge!(name: "ok"))
      array = Class.new(Array).new(["abc"])
      string = Class.new(String).new("abcdef")

      result = Julewire::Core::Serialization::BoundedTransform.call(
        hash.merge(items: array, message: string),
        max_string_bytes: 3
      )

      assert_equal({ name: "ok" }, result.fetch(:payload))
      assert_equal ["abc"], result.fetch(:items)
      refute_same array, result.fetch(:items)
      assert_equal "abc...[Truncated]", result.fetch(:message)
    end

    def test_string_limit_is_inclusive
      result = Julewire::Core::Serialization::BoundedTransform.call({ message: "abc" }, max_string_bytes: 3)

      assert_equal "abc", result.fetch(:message)
      assert_false result.key?(:_julewire_truncation)
    end

    def test_truncated_string_prefix_is_scrubbed_to_valid_utf8
      result = Julewire::Core::Serialization::BoundedTransform.call(
        { message: "aéz" },
        max_string_bytes: 2
      )

      assert_equal "a?...[Truncated]", result.fetch(:message)
      assert_predicate result.fetch(:message), :valid_encoding?
    end

    def test_clean_mutable_strings_are_copied
      source = +"abc"

      result = Julewire::Core::Serialization::BoundedTransform.call({ message: source }, max_string_bytes: 3)
      source << " mutated"

      assert_equal "abc", result.fetch(:message)
      refute_same source, result.fetch(:message)
    end

    def test_clean_frozen_strings_are_reused
      source = "abc"

      result = Julewire::Core::Serialization::BoundedTransform.call({ message: source }, max_string_bytes: 3)

      assert_same source, result.fetch(:message)
    end

    def test_clean_string_subclasses_are_copied
      source = Class.new(String).new("abc")

      result = Julewire::Core::Serialization::BoundedTransform.call({ message: source }, max_string_bytes: 3)

      assert_equal "abc", result.fetch(:message)
      refute_same source, result.fetch(:message)
    end

    def test_non_string_max_depth_marker_is_reused
      marker = Object.new

      result = transform_with_depth_marker(marker)

      assert_same marker, result.fetch(:nested)
    end

    def test_string_max_depth_marker_is_copied
      marker = +"[Hidden]"

      result = transform_with_depth_marker(marker)

      assert_equal "[Hidden]", result.fetch(:nested)
      refute_same marker, result.fetch(:nested)
    end

    def test_sibling_truncation_state_does_not_leak
      result = Julewire::Core::Serialization::BoundedTransform.call(
        { long: "abcdef", short: "ok" },
        max_string_bytes: 3
      )

      assert_equal "abc...[Truncated]", result.fetch(:long)
      assert_equal "ok", result.fetch(:short)
      assert_equal ["long"], result.dig(:_julewire_truncation, :truncated_fields)
    end

    def test_hash_truncation_metadata_accumulates_multiple_child_truncations
      result = Julewire::Core::Serialization::BoundedTransform.call(
        { first: "abcdef", second: "ghijkl" },
        max_string_bytes: 3
      )

      assert_equal "abc...[Truncated]", result.fetch(:first)
      assert_equal "ghi...[Truncated]", result.fetch(:second)
      assert_equal %w[first second], result.dig(:_julewire_truncation, :truncated_fields)
    end

    def test_hash_preserves_child_value_truncation_metadata
      result = Julewire::Core::Serialization::BoundedTransform.call(
        { payload: { token: "abcdef", empty: nil } },
        max_string_bytes: 3
      )

      assert_equal "abc...[Truncated]", result.dig(:payload, :token)
      assert_equal ["token"], result.dig(:payload, :_julewire_truncation, :truncated_fields)
    end

    def test_hash_reports_retained_child_truncation_on_parent_metadata
      result = Julewire::Core::Serialization::BoundedTransform.call(
        { payload: { token: "abcdef", empty: nil } },
        max_string_bytes: 3
      )

      assert_equal ["payload"], result.dig(:_julewire_truncation, :truncated_fields)
    end

    def test_truncation_metadata_deduplicates_repeated_fields
      result = Julewire::Core::Serialization::BoundedTransform.call(
        { items: %w[abcdef ghijkl] },
        max_string_bytes: 3
      )

      assert_equal ["array_items"], result.dig(:items, 2, :_julewire_truncation, :truncated_fields)
    end

    def test_public_truncation_metadata_owns_deduplicated_field_list
      fields = %w[array_items array_items]

      metadata = Julewire::Core::Serialization::Serializer.truncation_metadata(fields)
      fields << "hash_keys"

      assert_equal ["array_items"], metadata.fetch("truncated_fields")
    end

    def test_truncation_metadata_reports_all_limits
      result = Julewire::Core::Serialization::BoundedTransform.call(
        { one: 1, two: 2 },
        max_array_items: 7,
        max_depth: 3,
        max_hash_keys: 1,
        max_string_bytes: 5
      )

      limits = result.dig(:_julewire_truncation, :limits)

      assert_true result.dig(:_julewire_truncation, :truncated)
      assert_equal ["hash_keys"], result.dig(:_julewire_truncation, :truncated_fields)
      assert_equal 7, limits.fetch(:max_array_items)
      assert_equal 3, limits.fetch(:max_depth)
      assert_equal 1, limits.fetch(:max_hash_keys)
      assert_equal 5, limits.fetch(:max_string_bytes)
    end

    def test_hash_truncation_metadata_can_be_omitted
      result = Julewire::Core::Serialization::BoundedTransform.call(
        { one: 1, two: 2 },
        max_hash_keys: 1,
        truncation_key: nil
      )

      assert_equal({ one: 1 }, result)
      refute_includes result, nil
    end

    def test_array_truncation_metadata_can_be_omitted
      result = Julewire::Core::Serialization::BoundedTransform.call(
        [1, 2],
        max_array_items: 1,
        truncation_key: nil
      )

      assert_equal [1], result
    end

    def test_transform_stage_errors_bubble
      broken = Class.new(Hash) do
        def each
          raise "boom"
        end
      end.new

      error = assert_raises(RuntimeError) do
        Julewire::Core::Serialization::BoundedTransform.call(broken)
      end

      assert_equal "boom", error.message
    end

    def test_marks_hash_and_array_cycles
      hash_cycle = {}
      hash_cycle[:self] = hash_cycle
      array_cycle = []
      array_cycle << array_cycle

      result = Julewire::Core::Serialization::BoundedTransform.call(
        { hash_cycle: hash_cycle, array_cycle: array_cycle },
        max_depth: 5
      )

      assert_equal "[Circular]", result.dig(:hash_cycle, :self)
      assert_equal "[Circular]", result.dig(:array_cycle, 0)
    end

    def test_cycle_markers_add_transform_stage_truncation_metadata
      value = {}
      value[:self] = value

      result = Julewire::Core::Serialization::BoundedTransform.call(value)

      assert_equal "[Circular]", result.fetch(:self)
      assert_true result.dig(:_julewire_truncation, :truncated)
      assert_includes result.dig(:_julewire_truncation, :truncated_fields), "self"
    end

    def test_rejects_invalid_limits
      assert_raises_message(ArgumentError, "max_depth must be a positive Integer") do
        Julewire::Core::Serialization::BoundedTransform.call({}, max_depth: 0)
      end
      assert_raises_message(ArgumentError, "max_string_bytes must be a non-negative Integer") do
        Julewire::Core::Serialization::BoundedTransform.call({}, max_string_bytes: -1)
      end
      assert_raises_message(ArgumentError, "max_array_items must be a non-negative Integer") do
        Julewire::Core::Serialization::BoundedTransform.call({}, max_array_items: nil)
      end
      assert_raises_message(ArgumentError, "max_hash_keys must be a non-negative Integer") do
        Julewire::Core::Serialization::BoundedTransform.call({}, max_hash_keys: "1")
      end
    end

    def transform_with_depth_marker(marker)
      Julewire::Core::Serialization::BoundedTransform.call(
        { nested: { value: "hidden" } },
        max_depth: 1,
        max_depth_value: marker
      )
    end
  end
end
