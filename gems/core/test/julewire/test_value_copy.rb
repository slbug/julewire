# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestValueCopy < Minitest::Test
    cover Julewire::Core::Serialization::ValueCopy
    cover "Julewire::Core::Serialization::ValueCopy#copy_container"
    cover "Julewire::Core::Serialization::ValueCopy#copy_array"
    cover "Julewire::Core::Serialization::ValueCopy#copy_hash"
    cover "Julewire::Core::Serialization::ValueCopyTruncation#finish_array"
    cover "Julewire::Core::Serialization::ValueCopyTruncation#finish_container"
    cover "Julewire::Core::Serialization::ValueCopyTruncation#truncation_metadata"
    cover "Julewire::Core::Serialization::ValueCopy.omitted_empty?"
    cover "Julewire::Core::Serialization::ValueTraversal"
    ValueCopy = Julewire::Core::Serialization::ValueCopy
    def test_root_frozen_string_is_reused_by_public_copy
      source = (+"value").freeze

      assert_same source, ValueCopy.call(source)
      assert_same source, ValueCopy.call(source, freeze_values: true)
    end

    def test_root_immutable_and_opaque_leaf_values_are_reused
      object = Object.new

      assert_nil ValueCopy.call(nil)
      assert_true ValueCopy.call(true)
      assert_same :value, ValueCopy.call(:value)
      assert_same object, ValueCopy.call(object, freeze_values: true)
    end

    def test_root_array_subclass_is_copied_as_container
      source = Class.new(Array).new.push("value")

      copied = ValueCopy.call(source)

      assert_equal ["value"], copied
      assert_instance_of Array, copied
      refute_same source, copied
      refute_instance_of source.class, copied
    end

    def test_hash_limit_preserves_child_truncation_fields
      copied = ValueCopy.call(
        { first: "abcdef", second: "unvisited" },
        max_hash_keys: 1,
        max_string_bytes: 3
      )

      assert_equal "abc...[Truncated]", copied.fetch(:first)
      assert_symbol_truncation_metadata copied.fetch(:_julewire_truncation),
                                        fields: %w[first hash_keys],
                                        max_hash_keys: 1,
                                        max_string_bytes: 3
    end

    def test_hash_limit_inside_array_marks_parent_when_hash_limit_tracks_only_limit
      copied = ValueCopy.call(
        [{ first: 1, second: 2 }],
        max_hash_keys: 1
      )

      assert_equal 1, copied.dig(0, :first)
      refute_includes copied.fetch(0), :second
      assert_symbol_truncation_metadata copied.dig(0, :_julewire_truncation),
                                        fields: ["hash_keys"],
                                        max_hash_keys: 1
      assert_symbol_truncation_metadata copied.dig(1, :_julewire_truncation),
                                        fields: ["array_item_values"],
                                        max_hash_keys: 1
    end

    def test_copy_serializes_repeated_sibling_containers_independently
      shared = { value: 1 }

      copied = ValueCopy.call({ first: shared, second: shared })

      assert_equal({ value: 1 }, copied.fetch(:first))
      assert_equal({ value: 1 }, copied.fetch(:second))
    end

    def test_copy_tracks_active_containers_by_identity
      equal_hash = Class.new(Hash) do
        def hash = 1

        def eql?(_other) = true
      end
      child = equal_hash.new.merge!(value: 1)
      parent = equal_hash.new.merge!(child: child)

      copied = ValueCopy.call(parent)

      assert_equal({ value: 1 }, copied.fetch(:child))
    end

    def test_copy_tracks_deep_equal_containers_by_identity
      equal_hash = Class.new(Hash) do
        def hash = 1

        def eql?(_other) = true
      end
      containers = Array.new(6) { equal_hash.new }
      containers.each_cons(2) { |parent, child| parent[:child] = child }
      containers.last[:value] = 1

      copied = ValueCopy.call(containers.first)

      assert_equal 1, copied.dig(:child, :child, :child, :child, :child, :value)
    end

    def test_copy_keeps_parent_marked_after_repeated_circular_reference
      value = []
      value << value
      value << value

      copied = ValueCopy.call(value, max_depth: 2)

      assert_equal Julewire::Core::CIRCULAR_REFERENCE, copied.fetch(0)
      assert_equal Julewire::Core::CIRCULAR_REFERENCE, copied.fetch(1)
    end

    def test_public_copy_supports_reentrant_copy
      nested_copies = []
      source_class = Class.new(Hash) do
        define_method(:each) do |&block|
          nested_copies << ValueCopy.call({ nested: "ok" })
          super(&block)
        end
      end
      source = source_class.new
      source[:self] = source

      copied = ValueCopy.call(source)

      assert_equal [{ nested: "ok" }], nested_copies
      assert_equal Julewire::Core::CIRCULAR_REFERENCE, copied.fetch(:self)
    end

    def test_array_limit_preserves_child_truncation_fields
      copied = ValueCopy.call(
        %w[abcdef unvisited],
        max_array_items: 1,
        max_string_bytes: 3
      )

      assert_equal "abc...[Truncated]", copied.fetch(0)
      assert_symbol_truncation_metadata copied.fetch(1).fetch(:_julewire_truncation),
                                        fields: %w[array_item_values array_items],
                                        max_array_items: 1,
                                        max_string_bytes: 3
    end

    def test_bounded_array_without_truncation_does_not_emit_empty_metadata
      copied = ValueCopy.call(
        [1, 2],
        max_array_items: 10,
        max_string_bytes: 10
      )

      assert_equal [1, 2], copied
    end

    def test_array_child_depth_uses_next_depth
      copied = ValueCopy.call([[[1]]], max_depth: 2)

      assert_equal [Julewire::Core::Serialization::Serializer::MAX_DEPTH_VALUE], copied.fetch(0)
    end

    def test_array_child_depth_marks_truncation_when_tracking_is_active
      copied = ValueCopy.call([[[1]]], max_array_items: 10, max_depth: 2)

      assert_equal Julewire::Core::Serialization::Serializer::MAX_DEPTH_VALUE, copied.dig(0, 0)
      assert_symbol_truncation_metadata copied.dig(0, 1, :_julewire_truncation),
                                        fields: ["array_item_values"],
                                        max_array_items: 10,
                                        max_depth: 2
      assert_symbol_truncation_metadata copied.fetch(1).fetch(:_julewire_truncation),
                                        fields: ["array_item_values"],
                                        max_array_items: 10,
                                        max_depth: 2
    end

    def test_hash_child_depth_uses_next_depth
      copied = ValueCopy.call({ nested: { leaf: { value: 1 } } }, max_depth: 2)

      assert_equal(
        Julewire::Core::Serialization::Serializer::MAX_DEPTH_VALUE,
        copied.dig(:nested, :leaf)
      )
    end

    def test_hash_child_depth_without_tracking_does_not_inject_truncation_metadata
      copied = ValueCopy.call({ nested: { leaf: { value: 1 } } }, max_depth: 2)

      assert_equal(
        Julewire::Core::Serialization::Serializer::MAX_DEPTH_VALUE,
        copied.dig(:nested, :leaf)
      )
      assert_false copied.key?(:_julewire_truncation)
    end

    def test_nil_depth_keeps_unbounded_copy_mode
      value = { first: { second: { third: "ok" } } }

      assert_equal value, ValueCopy.call(value, max_depth: nil)
    end

    def test_freeze_values_reuses_frozen_empty_containers
      copied_hash = ValueCopy.call({}, freeze_values: true)
      copied_array = ValueCopy.call([], freeze_values: true)

      assert_equal({}, copied_hash)
      assert_equal([], copied_array)
      assert_same copied_hash, ValueCopy.call({}, freeze_values: true)
      assert_same copied_array, ValueCopy.call([], freeze_values: true)
      assert_predicate copied_hash, :frozen?
      assert_predicate copied_array, :frozen?
    end

    def test_default_copy_keeps_empty_containers_mutable
      copied_hash = ValueCopy.call({})
      copied_array = ValueCopy.call([])

      copied_hash[:added] = true
      copied_array << :added

      assert_equal({ added: true }, copied_hash)
      assert_equal [:added], copied_array
    end

    def test_freeze_values_treats_empty_hash_subclasses_as_hashes
      empty_hash = Class.new(Hash).new

      copied = ValueCopy.call(empty_hash, freeze_values: true)

      assert_equal({}, copied)
      assert_predicate copied, :frozen?
    end

    def test_nested_hash_subclasses_are_copied_as_hashes
      hash_class = Class.new(Hash)
      nested = hash_class.new
      nested[:message] = "abcdef"

      copied = ValueCopy.call({ nested: nested }, max_string_bytes: 3)

      assert_equal "abc...[Truncated]", copied.dig(:nested, :message)
      assert_symbol_truncation_metadata copied.fetch(:_julewire_truncation),
                                        fields: ["nested"],
                                        max_string_bytes: 3
    end

    def test_nested_array_subclasses_are_copied_as_arrays
      array_class = Class.new(Array)
      nested = array_class.new
      nested << "abcdef"

      copied = ValueCopy.call([nested], max_array_items: 10, max_string_bytes: 3)

      assert_equal "abc...[Truncated]", copied.dig(0, 0)
      assert_symbol_truncation_metadata copied.fetch(1).fetch(:_julewire_truncation),
                                        fields: ["array_item_values"],
                                        max_array_items: 10,
                                        max_string_bytes: 3
    end

    def test_symbolized_copy_rejects_object_keys
      error = assert_raises(TypeError) do
        ValueCopy.call({ Object.new => "value" }, symbolize_keys: true)
      end

      assert_equal "field keys must be String or Symbol", error.message
    end

    def test_unsymbolized_copy_preserves_object_keys
      key = Object.new

      copied = ValueCopy.call({ key => "value" }, symbolize_keys: false)

      assert_equal [key], copied.keys
      assert_equal "value", copied.fetch(key)
    end

    def test_unsymbolized_string_keys_stay_strings
      copied = ValueCopy.call({ "key" => "value" }, symbolize_keys: false)

      assert_equal ["key"], copied.keys
    end

    def test_string_keys_stay_strings_by_default
      copied = ValueCopy.call({ "key" => "value" })

      assert_equal ["key"], copied.keys
    end

    def test_symbolized_string_keys_become_symbols
      copied = ValueCopy.call({ "key" => "value" }, symbolize_keys: true)

      assert_equal [:key], copied.keys
    end

    def test_string_subclass_keys_are_symbolized
      string_class = Class.new(String)

      copied = ValueCopy.call({ string_class.new("key") => "value" }, symbolize_keys: true)

      assert_equal [:key], copied.keys
    end

    def test_string_subclass_values_are_copied_as_strings
      string_class = Class.new(String)

      copied = ValueCopy.call([string_class.new("abcdef")], max_string_bytes: 3)

      assert_equal "abc...[Truncated]", copied.fetch(0)
    end

    def test_root_string_subclass_values_are_bounded_as_strings
      string_class = Class.new(String)

      copied = ValueCopy.call(string_class.new("abcdef"), max_string_bytes: 3)

      assert_equal "abc...[Truncated]", copied
    end

    def test_root_string_subclass_values_honor_freeze_values
      string_class = Class.new(String)

      copied = ValueCopy.call(string_class.new("value"), freeze_values: true)

      assert_equal "value", copied
      assert_instance_of string_class, copied
      assert_predicate copied, :frozen?
    end

    def test_string_copy_truncates_scrubbed_bytes
      copied = ValueCopy.call("#{invalid_utf8_string} suffix", max_string_bytes: 7)

      assert_equal "token ?...[Truncated]", copied
    end

    def test_string_copy_honors_freeze_values
      source = +"value"

      copied = ValueCopy.call(source, freeze_values: true)

      refute_same source, copied
      assert_predicate copied, :frozen?
    end

    def test_string_copy_can_leave_values_mutable
      source = +"value"

      copied = ValueCopy.call(source, freeze_values: false)

      refute_same source, copied
      refute_predicate copied, :frozen?
    end

    def test_container_copy_defaults_to_mutable_containers_and_string_values
      source = +"value"

      copied = ValueCopy.call({ text: source })

      refute_predicate copied, :frozen?
      refute_same source, copied.fetch(:text)
      refute_predicate copied.fetch(:text), :frozen?
    end

    def test_container_copy_can_leave_containers_and_string_values_mutable
      source = +"value"

      copied = ValueCopy.call({ text: source }, freeze_values: false)

      refute_predicate copied, :frozen?
      refute_same source, copied.fetch(:text)
      refute_predicate copied.fetch(:text), :frozen?
    end

    def test_truncated_string_copy_honors_freeze_values
      copied = ValueCopy.call("abcdef", freeze_values: true, max_string_bytes: 3)

      assert_equal "abc...[Truncated]", copied
      assert_predicate copied, :frozen?
    end

    def test_nested_string_copy_honors_freeze_values_without_truncation
      source = +"value"

      copied = ValueCopy.call({ text: source }, freeze_values: true).fetch(:text)

      refute_same source, copied
      assert_predicate copied, :frozen?
    end

    def test_frozen_string_values_are_reused_inside_containers
      source = "value"

      copied = ValueCopy.call([source]).fetch(0)

      assert_same source, copied
    end

    def test_time_copy_honors_freeze_values
      source = Time.now

      copied = ValueCopy.call({ at: source }, freeze_values: true).fetch(:at)

      refute_same source, copied
      assert_equal source, copied
      assert_predicate copied, :frozen?
    end

    def test_frozen_time_is_reused
      source = Time.now.freeze

      copied = ValueCopy.call({ at: source }, freeze_values: true).fetch(:at)

      assert_same source, copied
    end

    def test_time_subclasses_are_copied_as_times
      time_class = Class.new(Time)
      source = time_class.at(Time.now.to_f)

      copied = ValueCopy.call({ at: source }, freeze_values: true).fetch(:at)

      refute_same source, copied
      assert_instance_of time_class, copied
      assert_predicate copied, :frozen?
    end

    def test_root_time_subclasses_honor_freeze_values
      time_class = Class.new(Time)
      source = time_class.at(Time.now.to_f)

      copied = ValueCopy.call(source, freeze_values: true)

      refute_same source, copied
      assert_instance_of time_class, copied
      assert_predicate copied, :frozen?
    end

    def test_time_is_reused_without_freeze_values
      source = Time.now

      copied = ValueCopy.call({ at: source }, freeze_values: false).fetch(:at)

      assert_same source, copied
    end

    def test_root_time_copy_honors_freeze_values
      source = Time.now

      copied = ValueCopy.call(source, freeze_values: true)

      refute_same source, copied
      assert_equal source, copied
      assert_predicate copied, :frozen?
    end

    def test_root_frozen_time_is_reused
      source = Time.now.freeze

      copied = ValueCopy.call(source, freeze_values: true)

      assert_same source, copied
    end

    def test_root_time_is_reused_without_freeze_values
      source = Time.now

      copied = ValueCopy.call(source, freeze_values: false)

      assert_same source, copied
    end

    def test_non_time_leaf_values_are_not_frozen
      object = Object.new

      copied = ValueCopy.call({ object: object }, freeze_values: true).fetch(:object)

      assert_same object, copied
      refute_predicate copied, :frozen?
    end

    def test_compact_empty_false_preserves_empty_hash_entries_and_array_items
      copied_hash = ValueCopy.call({ empty: {}, nil_value: nil }, compact_empty: false)
      copied_array = ValueCopy.call([{}, nil], compact_empty: false)

      assert_equal({ empty: {}, nil_value: nil }, copied_hash)
      assert_equal [{}, nil], copied_array
    end

    def test_default_copy_preserves_empty_hash_entries_and_array_items
      copied_hash = ValueCopy.call({ empty: {}, nil_value: nil })
      copied_array = ValueCopy.call([{}, nil])

      assert_equal({ empty: {}, nil_value: nil }, copied_hash)
      assert_equal [{}, nil], copied_array
    end

    def test_compact_empty_true_omits_empty_hash_entries_and_array_items
      copied_hash = ValueCopy.call(
        { empty: {}, nil_value: nil, value: { id: 1 } },
        compact_empty: true
      )
      copied_array = ValueCopy.call([{}, nil, { id: 1 }], compact_empty: true)

      assert_equal({ value: { id: 1 } }, copied_hash)
      assert_equal [{ id: 1 }], copied_array
    end

    def test_compact_hash_counts_raw_empty_entries_once_before_limit
      copied = ValueCopy.call(
        { empty: {}, keep: { id: 1 }, later: { id: 2 } },
        compact_empty: true,
        max_hash_keys: 2
      )

      assert_equal({ id: 1 }, copied.fetch(:keep))
      refute_includes copied, :empty
      refute_includes copied, :later
      assert_symbol_truncation_metadata copied.fetch(:_julewire_truncation),
                                        fields: ["hash_keys"],
                                        max_hash_keys: 2
    end

    def test_compact_array_counts_raw_empty_entries_once_before_limit
      copied = ValueCopy.call(
        [nil, { id: 1 }, { id: 2 }],
        compact_empty: true,
        max_array_items: 2
      )

      assert_equal({ id: 1 }, copied.fetch(0))
      assert_equal 2, copied.length
      assert_symbol_truncation_metadata copied.fetch(1).fetch(:_julewire_truncation),
                                        fields: ["array_items"],
                                        max_array_items: 2
    end

    def test_compact_array_skips_raw_empty_containers_before_walking
      broken_empty_hash = Class.new(Hash) do
        def each
          raise "should not walk omitted empty hash"
        end
      end.new
      broken_empty_array = Class.new(Array) do
        def each
          raise "should not walk omitted empty array"
        end
      end.new

      copied = ValueCopy.call(
        [broken_empty_hash, broken_empty_array, { keep: true }],
        compact_empty: true
      )

      assert_equal [{ keep: true }], copied
    end

    def test_compact_array_omission_preserves_previous_truncation_fields
      copied = ValueCopy.call(
        ["abcdef", []],
        compact_empty: true,
        max_string_bytes: 3
      )

      assert_equal "abc...[Truncated]", copied.fetch(0)
      assert_equal 2, copied.length
      assert_symbol_truncation_metadata copied.fetch(1).fetch(:_julewire_truncation),
                                        fields: ["array_item_values"],
                                        max_string_bytes: 3
    end

    def test_compact_array_copied_omission_preserves_previous_truncation_fields
      copied = ValueCopy.call(
        ["abcdef", { ignored: [] }, "ok"],
        compact_empty: true,
        max_string_bytes: 3
      )

      assert_equal "abc...[Truncated]", copied.fetch(0)
      assert_equal "ok", copied.fetch(1)
      assert_equal 3, copied.length
      assert_symbol_truncation_metadata copied.fetch(2).fetch(:_julewire_truncation),
                                        fields: ["array_item_values"],
                                        max_string_bytes: 3
    end

    def test_array_copy_preserves_fields_from_multiple_entries
      copied = ValueCopy.call(
        %w[abcdef ghijkl],
        max_string_bytes: 3
      )

      assert_equal "abc...[Truncated]", copied.fetch(0)
      assert_equal "ghi...[Truncated]", copied.fetch(1)
      assert_symbol_truncation_metadata copied.fetch(2).fetch(:_julewire_truncation),
                                        fields: ["array_item_values"],
                                        max_string_bytes: 3
    end

    def test_array_copy_keeps_previous_truncation_fields_after_clean_item
      copied = ValueCopy.call(
        %w[abcdef ok],
        max_string_bytes: 3
      )

      assert_equal "abc...[Truncated]", copied.fetch(0)
      assert_equal "ok", copied.fetch(1)
      assert_symbol_truncation_metadata copied.fetch(2).fetch(:_julewire_truncation),
                                        fields: ["array_item_values"],
                                        max_string_bytes: 3
    end

    def test_hash_copy_preserves_fields_from_multiple_entries
      copied = ValueCopy.call(
        { first: "abcdef", second: "ghijkl" },
        max_string_bytes: 3
      )

      assert_equal "abc...[Truncated]", copied.fetch(:first)
      assert_equal "ghi...[Truncated]", copied.fetch(:second)
      assert_symbol_truncation_metadata copied.fetch(:_julewire_truncation),
                                        fields: %w[first second],
                                        max_string_bytes: 3
    end

    def test_hash_copy_preserves_child_truncation_before_clean_string_key_copy
      copied = ValueCopy.call(
        { "id" => "abcdef" },
        max_string_bytes: 3,
        symbolize_keys: false
      )

      assert_equal "abc...[Truncated]", copied.fetch("id")
      assert_symbol_truncation_metadata copied.fetch(:_julewire_truncation),
                                        fields: ["id"],
                                        max_string_bytes: 3
    end

    def test_hash_copy_keeps_previous_truncation_fields_after_clean_sibling
      copied = ValueCopy.call(
        { first: "abcdef", second: "ok" },
        max_string_bytes: 3
      )

      assert_equal "abc...[Truncated]", copied.fetch(:first)
      assert_equal "ok", copied.fetch(:second)
      assert_symbol_truncation_metadata copied.fetch(:_julewire_truncation),
                                        fields: ["first"],
                                        max_string_bytes: 3
    end

    def test_hash_copy_clears_child_truncation_before_clean_scalar_sibling
      copied = ValueCopy.call(
        { first: "abcdef", second: 1 },
        max_string_bytes: 3
      )

      assert_equal "abc...[Truncated]", copied.fetch(:first)
      assert_equal 1, copied.fetch(:second)
      assert_symbol_truncation_metadata copied.fetch(:_julewire_truncation),
                                        fields: ["first"],
                                        max_string_bytes: 3
    end

    def test_compact_hash_omission_preserves_previous_truncation_fields
      copied = ValueCopy.call(
        { first: "abcdef", second: [] },
        compact_empty: true,
        max_string_bytes: 3
      )

      assert_equal "abc...[Truncated]", copied.fetch(:first)
      assert_symbol_truncation_metadata copied.fetch(:_julewire_truncation),
                                        fields: ["first"],
                                        max_string_bytes: 3
    end

    def test_compact_hash_copied_omission_preserves_previous_truncation_fields
      copied = ValueCopy.call(
        { first: "abcdef", second: { ignored: [] } },
        compact_empty: true,
        max_string_bytes: 3
      )

      assert_equal "abc...[Truncated]", copied.fetch(:first)
      refute_includes copied, :second
      assert_symbol_truncation_metadata copied.fetch(:_julewire_truncation),
                                        fields: ["first"],
                                        max_string_bytes: 3
    end

    def test_invalid_array_limit_names_value_copy_option
      error = assert_raises(ArgumentError) { ValueCopy.call([], max_array_items: -1) }

      assert_equal "max_array_items must be a non-negative Integer", error.message
    end

    def test_invalid_hash_limit_names_value_copy_option
      error = assert_raises(ArgumentError) { ValueCopy.call({}, max_hash_keys: -1) }

      assert_equal "max_hash_keys must be a non-negative Integer", error.message
    end

    def test_invalid_string_limit_names_value_copy_option
      error = assert_raises(ArgumentError) { ValueCopy.call("value", max_string_bytes: -1) }

      assert_equal "max_string_bytes must be a non-negative Integer", error.message
    end

    def test_omitted_empty_accepts_array_subclasses
      assert_true ValueCopy.omitted_empty?(Class.new(Array).new)
    end

    def test_omitted_empty_matches_only_nil_and_empty_containers
      assert_true ValueCopy.omitted_empty?(nil)
      assert_true ValueCopy.omitted_empty?({})
      assert_true ValueCopy.omitted_empty?([])
      assert_true ValueCopy.omitted_empty?(Class.new(Hash).new)

      assert_false ValueCopy.omitted_empty?({ value: nil })
      assert_false ValueCopy.omitted_empty?([nil])
      assert_false ValueCopy.omitted_empty?("")
      assert_false ValueCopy.omitted_empty?(false)
    end

    def test_string_truncation_metadata_requires_symbolizing_when_preserved
      error = assert_raises(ArgumentError) do
        ValueCopy.call(
          { "_julewire_truncation" => string_truncation_metadata },
          preserve_truncation_metadata: true,
          symbolize_keys: false
        )
      end

      assert_equal "_julewire_truncation is reserved for Julewire truncation metadata", error.message
    end

    def test_preserved_metadata_stays_canonical_symbol_keyed_when_regular_keys_are_not_symbolized
      copied = ValueCopy.call(
        { _julewire_truncation: string_truncation_metadata },
        preserve_truncation_metadata: true,
        symbolize_keys: false
      )

      assert_symbol_truncation_metadata copied.fetch(:_julewire_truncation), fields: ["field"]
    end

    def test_preserved_metadata_uses_default_field_limit_without_custom_array_limit
      metadata = string_truncation_metadata.merge(
        "truncated_fields" => Array.new(Julewire::Core::Serialization::Serializer::DEFAULT_MAX_ARRAY_ITEMS + 1) do
          "field"
        end
      )

      error = assert_raises(ArgumentError) do
        ValueCopy.call(
          { "_julewire_truncation" => metadata },
          preserve_truncation_metadata: true,
          symbolize_keys: true
        )
      end

      assert_equal "_julewire_truncation is reserved for Julewire truncation metadata", error.message
    end

    def test_preserved_metadata_is_not_retruncated_as_payload
      metadata = {
        truncated: true,
        truncated_fields: ["abcdef"],
        limits: { max_string_bytes: 100 }
      }

      copied = ValueCopy.call(
        { _julewire_truncation: metadata },
        max_string_bytes: 3,
        preserve_truncation_metadata: true
      )

      assert_symbol_truncation_metadata copied.fetch(:_julewire_truncation),
                                        fields: ["abcdef"],
                                        max_string_bytes: 100
    end

    def test_fresh_truncation_metadata_replaces_preserved_metadata
      copied = ValueCopy.call(
        { first: "abcdef", _julewire_truncation: symbol_truncation_metadata },
        max_string_bytes: 3,
        preserve_truncation_metadata: true
      )

      assert_equal "abc...[Truncated]", copied.fetch(:first)
      assert_symbol_truncation_metadata copied.fetch(:_julewire_truncation),
                                        fields: ["first"],
                                        max_string_bytes: 3
    end

    def test_preserved_metadata_honors_freeze_values
      copied = ValueCopy.call(
        { _julewire_truncation: symbol_truncation_metadata },
        freeze_values: true,
        preserve_truncation_metadata: true
      )
      metadata = copied.fetch(:_julewire_truncation)

      assert_predicate metadata, :frozen?
      assert_predicate metadata.fetch(:truncated_fields), :frozen?
      assert_predicate metadata.fetch(:truncated_fields).fetch(0), :frozen?
      assert_predicate metadata.fetch(:limits), :frozen?
    end

    def test_generated_array_truncation_metadata_honors_freeze_values
      copied = ValueCopy.call(
        %w[abcdef unvisited],
        freeze_values: true,
        max_array_items: 1,
        max_string_bytes: 3
      )
      metadata_wrapper = copied.fetch(1)
      metadata = metadata_wrapper.fetch(:_julewire_truncation)

      assert_predicate copied, :frozen?
      assert_predicate metadata_wrapper, :frozen?
      assert_predicate metadata, :frozen?
      assert_predicate metadata.fetch(:truncated_fields), :frozen?
      assert_predicate metadata.fetch(:limits), :frozen?
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
        truncated_fields: [+"field"],
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
