# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestFieldSet < Minitest::Test
    cover Julewire::Core::Fields::FieldSet
    cover Julewire::Core::Fields::Internal
    cover "Julewire::Core::Fields::Lookup.value"
    cover "Julewire::Core::Fields::Lookup.wire_value"
    cover "Julewire::Core::Fields::Lookup.blank?"
    cover "Julewire::Core::Fields::FieldSet.coerce_fields!"
    cover "Julewire::Core::Fields::FieldSet.deep_symbolize_owned_keys"
    cover "Julewire::Core::Fields::FieldSet.normalized_field_key"
    cover "Julewire::Core::Fields::Internal.frozen_copy"

    def test_lookup_value_uses_the_requested_key_without_cross_form_fallback
      fields = { key: false, "fallback" => "string", nil_key: nil, "nil_key" => "from-string" }
      index_only = Object.new
      def index_only.[](key) = key == "index_only" ? "duck" : nil

      assert_false Julewire::Core::Fields::Lookup.value(fields, :key)
      assert_nil Julewire::Core::Fields::Lookup.value(fields, :fallback)
      assert_equal "string", Julewire::Core::Fields::Lookup.value(fields, "fallback")
      assert_nil Julewire::Core::Fields::Lookup.value(fields, :nil_key)
      assert_equal "duck", Julewire::Core::Fields::Lookup.value(index_only, "index_only")
      assert_nil Julewire::Core::Fields::Lookup.value(Object.new, :key)
    end

    def test_lookup_value_treats_reader_errors_as_absent
      source = Object.new
      def source.[](_key) = raise "broken reader"

      assert_nil Julewire::Core::Fields::Lookup.value(source, :key)
    end

    def test_wire_lookup_normalizes_only_at_the_presentation_boundary
      fields = { "event" => "wire.event", event: "owned.event" }

      assert_equal "owned.event", Julewire::Core::Fields::Lookup.wire_value(fields, :event)
      assert_equal "wire.event", Julewire::Core::Fields::Lookup.wire_value({ "event" => "wire.event" }, :event)
    end

    def test_lookup_value_does_not_call_indexer_when_not_advertised
      touched = false
      source = Object.new
      source.define_singleton_method(:method_missing) do |method_name, *, &|
        touched = true if method_name == :[]
        nil
      end

      assert_nil Julewire::Core::Fields::Lookup.value(source, :key)
      assert_false touched
    end

    def test_lookup_blank_recognizes_nil_and_empty_values
      empty_duck = Object.new
      def empty_duck.empty? = true

      assert_true Julewire::Core::Fields::Lookup.blank?(nil)
      assert_true Julewire::Core::Fields::Lookup.blank?("")
      assert_true Julewire::Core::Fields::Lookup.blank?([])
      assert_true Julewire::Core::Fields::Lookup.blank?(empty_duck)
    end

    def test_lookup_blank_preserves_false_and_nonempty_values
      nonempty_duck = Object.new
      def nonempty_duck.empty? = false

      assert_false Julewire::Core::Fields::Lookup.blank?(false)
      assert_false Julewire::Core::Fields::Lookup.blank?(0)
      assert_false Julewire::Core::Fields::Lookup.blank?("value")
      assert_false Julewire::Core::Fields::Lookup.blank?(nonempty_duck)
    end

    def test_value_for_unknown_key_objects_rejects_unsupported_key_type
      fields = Array.new(32) { |index| [:"key#{index}", index] }.to_h
      key = Object.new

      def key.to_sym
        raise "should not symbolize"
      end

      error = assert_raises(TypeError) do
        Julewire::Core::Fields::FieldSet.value_for(fields, key)
      end

      assert_equal "field keys must be String or Symbol", error.message
    end

    def test_value_for_accepts_hash_and_string_subclasses
      hash = Class.new(Hash).new.merge!(safe: nil, subclass_key: 2)
      string_key = Class.new(String).new("subclass_key")

      assert_nil Julewire::Core::Fields::FieldSet.value_for(hash, :safe, default: :fallback)
      assert_equal 2, Julewire::Core::Fields::FieldSet.value_for(hash, string_key)
    end

    def test_value_for_uses_default_for_non_hash_and_missing_keys
      assert_equal :fallback, Julewire::Core::Fields::FieldSet.value_for(nil, :safe, default: :fallback)
      assert_equal :fallback, Julewire::Core::Fields::FieldSet.value_for({}, :safe, default: :fallback)
    end

    def test_normalize_key_accepts_string_subclasses
      key = Class.new(String).new("tenant_id")

      assert_equal :tenant_id, Julewire::Core::Fields::Internal.normalize_key(key)
    end

    def test_merge_accepts_string_subclass_keys
      key = Class.new(String).new("tenant_id")

      assert_equal(
        { tenant_id: "tenant-1" },
        Julewire::Core::Fields::FieldSet.merge!({}, key => "tenant-1")
      )
    end

    def test_merge_rejects_reserved_truncation_metadata_keys
      field_set = Julewire::Core::Fields::FieldSet
      reserved_key = Julewire::Core::Serialization::Serializer::TRUNCATION_METADATA_KEY

      [reserved_key, reserved_key.to_sym].each do |key|
        error = assert_raises(ArgumentError, key.inspect) do
          field_set.merge!({}, key => true)
        end

        assert_equal "_julewire_truncation is reserved for Julewire truncation metadata", error.message
      end
    end

    def test_delete_key_normalizes_string_keys
      target = { tenant_id: "tenant-1" }

      Julewire::Core::Fields::Internal.delete_key!(target, "tenant_id")

      assert_empty target
    end

    def test_coerce_wraps_non_hash_values_with_defensive_copy
      input = ["first"]

      coerced = Julewire::Core::Fields::FieldSet.coerce(input, {}, invalid: :wrap)
      input << "second"

      assert_equal({ value: ["first"] }, coerced)
    end

    def test_coerce_allows_nil_positional_fields_even_when_invalid_mode_raises
      assert_equal(
        { request_id: "req-1" },
        Julewire::Core::Fields::FieldSet.coerce(nil, { "request_id" => "req-1" }, invalid: :raise)
      )
    end

    def test_merge_rejects_non_string_non_symbol_keys_without_changing_target
      target = { "1" => "string", safe: true }

      error = assert_raises(TypeError) do
        Julewire::Core::Fields::FieldSet.merge!(target, 1 => "integer")
      end

      assert_equal "field keys must be String or Symbol", error.message
      assert_equal({ "1" => "string", safe: true }, target)
    end

    def test_coerce_ignores_invalid_non_hash_fields
      assert_empty Julewire::Core::Fields::FieldSet.coerce("ignored", invalid: :ignore)
      assert_empty Julewire::Core::Fields::FieldSet.coerce("ignored")
    end

    def test_coerce_raises_for_invalid_non_hash_fields
      error = assert_raises(ArgumentError) do
        Julewire::Core::Fields::FieldSet.coerce("invalid", invalid: :raise)
      end

      assert_equal "fields must be a Hash", error.message
    end

    def test_coerce_accepts_hash_subclasses
      fields = Class.new(Hash).new.merge!("request_id" => "req-1")

      assert_equal({ request_id: "req-1" }, Julewire::Core::Fields::FieldSet.coerce(fields, invalid: :raise))
    end

    def test_coerce_rejects_unknown_invalid_mode
      assert_raises_message(ArgumentError, "invalid field coercion mode: :explode") do
        Julewire::Core::Fields::FieldSet.coerce("ignored", invalid: :explode)
      end
    end

    def test_coerce_accepts_empty_input
      assert_empty Julewire::Core::Fields::FieldSet.coerce
    end

    def test_coerce_accepts_keyword_only_fields
      assert_equal(
        { request_id: "req-1" },
        Julewire::Core::Fields::FieldSet.coerce(nil, { "request_id" => "req-1" })
      )
    end

    def test_coerce_merges_positional_and_keyword_fields
      assert_equal(
        { event: "checkout", request_id: "req-1" },
        Julewire::Core::Fields::FieldSet.coerce({ "event" => "checkout" }, { "request_id" => "req-1" })
      )
    end

    def test_coerce_does_not_renormalize_bounded_positional_fields_when_merging_keywords
      defaults = Julewire::Core::Serialization::Serializer

      coerced = Julewire::Core::Fields::FieldSet.coerce(
        { payload: { "body" => "x" * (defaults::DEFAULT_MAX_STRING_BYTES + 1) } },
        { "request_id" => "req-1" }
      )

      assert_equal "req-1", coerced.fetch(:request_id)
      assert_match(/\.\.\.\[Truncated\]\z/, coerced.dig(:payload, :body))
      assert_symbol_truncation_metadata coerced.dig(:payload, :_julewire_truncation),
                                        fields: ["body"],
                                        max_array_items: defaults::DEFAULT_MAX_ARRAY_ITEMS,
                                        max_hash_keys: defaults::DEFAULT_MAX_HASH_KEYS,
                                        max_string_bytes: defaults::DEFAULT_MAX_STRING_BYTES
    end

    def test_merge_normalizes_left_without_mutating_caller
      left = { "account" => { "id" => "acct-1" } }

      merged = Julewire::Core::Fields::FieldSet.merge(left, {})

      assert_equal({ account: { id: "acct-1" } }, merged)
      assert_equal({ "account" => { "id" => "acct-1" } }, left)
    end

    def test_deep_symbolize_keys_applies_default_ingress_bounds
      copied = Julewire::Core::Fields::FieldSet.deep_symbolize_keys(
        default_ingress_bounds_payload
      )

      assert_default_ingress_bounds copied
      refute_predicate copied, :frozen?
    end

    def test_deep_symbolize_keys_rejects_valid_shaped_truncation_metadata_as_user_input
      error = assert_raises(ArgumentError) do
        Julewire::Core::Fields::FieldSet.deep_symbolize_keys(
          "_julewire_truncation" => field_truncation_metadata
        )
      end

      assert_equal "_julewire_truncation is reserved for Julewire truncation metadata", error.message
    end

    def test_deep_symbolize_owned_keys_preserves_owned_truncation_metadata
      metadata = {
        "truncated" => true,
        "truncated_fields" => ["field"],
        "limits" => { "max_string_bytes" => 10 }
      }

      copied = Julewire::Core::Fields::FieldSet.deep_symbolize_owned_keys(
        "_julewire_truncation" => metadata,
        "account" => { "id" => "acct-1" }
      )

      assert_equal "acct-1", copied.dig(:account, :id)
      assert_equal ["field"], copied.dig(:_julewire_truncation, :truncated_fields)
    end

    def test_deep_dup_owned_preserves_owned_truncation_metadata
      copied = Julewire::Core::Fields::FieldSet.deep_dup_owned(
        _julewire_truncation: field_truncation_metadata
      )

      assert_equal ["field"], copied.dig(:_julewire_truncation, :truncated_fields)
    end

    def test_internal_frozen_copy_deep_copies_and_freezes_values
      source = { account: { tags: ["pro"] } }

      copied = Julewire::Core::Fields::Internal.frozen_copy(source)
      source.fetch(:account).fetch(:tags) << "changed"

      assert_equal({ account: { tags: ["pro"] } }, copied)
      assert_predicate copied, :frozen?
      assert_predicate copied.fetch(:account), :frozen?
      assert_predicate copied.dig(:account, :tags), :frozen?
    end

    def test_deep_merge_accepts_hash_subclasses_and_normalizes_string_keys
      fields = Class.new(Hash).new.merge!("account" => { "id" => "acct-1" })
      target = { account: { plan: "pro" } }

      merged = Julewire::Core::Fields::Internal.deep_merge!(target, fields)

      assert_same target, merged
      assert_equal({ account: { plan: "pro", id: "acct-1" } }, target)
    end

    def test_deep_merge_ignores_non_hash_fields_without_replacing_target
      target = { account: { plan: "pro" } }

      merged = Julewire::Core::Fields::Internal.deep_merge!(target, [])

      assert_same target, merged
      assert_equal({ account: { plan: "pro" } }, target)
    end

    def test_deep_merge_ignores_truthy_non_hash_fields_without_iteration
      target = { account: { plan: "pro" } }

      merged = Julewire::Core::Fields::Internal.deep_merge!(target, "ignored")

      assert_same target, merged
      assert_equal({ account: { plan: "pro" } }, target)
    end

    def test_deep_merge_symbolizes_new_nested_hash_values
      target = {}

      Julewire::Core::Fields::Internal.deep_merge!(target, account: { "id" => "acct-1" })

      assert_equal({ account: { id: "acct-1" } }, target)
    end

    def test_deep_merge_replaces_existing_scalar_with_symbolized_hash
      target = { account: "old" }

      Julewire::Core::Fields::Internal.deep_merge!(target, account: { "id" => "acct-1" })

      assert_equal({ account: { id: "acct-1" } }, target)
    end

    def test_deep_merge_merges_hash_subclasses_on_both_sides
      existing = Class.new(Hash).new.merge!(plan: "pro")
      value = Class.new(Hash).new.merge!("id" => "acct-1")
      target = { account: existing }

      Julewire::Core::Fields::Internal.deep_merge!(target, account: value)

      assert_same existing, target.fetch(:account)
      assert_equal({ plan: "pro", id: "acct-1" }, target.fetch(:account))
    end

    def test_deep_merge_replaces_existing_hash_with_scalar_or_subclass_value
      value = Class.new(String).new("closed")
      target = { account: { plan: "pro" } }

      Julewire::Core::Fields::Internal.deep_merge!(target, account: value)

      assert_equal({ account: "closed" }, target)
      assert_same value.class, target.fetch(:account).class
    end

    def test_deep_merge_owned_keeps_owned_values_and_replaces_existing_hash_with_scalar
      value = Class.new(String).new("closed")
      target = { account: { plan: "pro" } }

      Julewire::Core::Fields::Internal.deep_merge_owned!(target, account: value)

      assert_same value, target.fetch(:account)
    end

    def test_deep_merge_owned_replaces_existing_scalar_with_owned_hash
      value = { "id" => "acct-1" }
      target = { account: "old" }

      Julewire::Core::Fields::Internal.deep_merge_owned!(target, account: value)

      assert_same value, target.fetch(:account)
    end

    def test_deep_merge_owned_merges_hash_subclasses_on_both_sides
      existing = Class.new(Hash).new.merge!(plan: "pro")
      value = Class.new(Hash).new.merge!("id" => "acct-1")
      target = { account: existing }

      Julewire::Core::Fields::Internal.deep_merge_owned!(target, account: value)

      assert_same existing, target.fetch(:account)
      assert_equal({ plan: "pro", "id" => "acct-1" }, target.fetch(:account))
    end

    def test_owned_merges_ignore_non_hash_fields_and_return_the_target
      target = { account: { id: "acct-1" } }

      assert_same target, Julewire::Core::Fields::Internal.merge_owned!(target, nil)
      assert_same target, Julewire::Core::Fields::Internal.deep_merge_owned!(target, Object.new)
      assert_equal({ account: { id: "acct-1" } }, target)
    end

    private

    def field_truncation_metadata
      {
        truncated: true,
        truncated_fields: ["field"],
        limits: { max_string_bytes: 10 }
      }
    end

    def default_ingress_bounds_payload
      defaults = Julewire::Core::Serialization::Serializer
      {
        "items" => Array.new(defaults::DEFAULT_MAX_ARRAY_ITEMS + 1, "x"),
        "keys" => Array.new(defaults::DEFAULT_MAX_HASH_KEYS + 1) { |index| ["key_#{index}", index] }.to_h,
        "body" => "x" * (defaults::DEFAULT_MAX_STRING_BYTES + 1)
      }
    end

    def assert_default_ingress_bounds(copied)
      defaults = Julewire::Core::Serialization::Serializer

      assert_equal defaults::DEFAULT_MAX_ARRAY_ITEMS + 1, copied.fetch(:items).length
      assert_symbol_truncation_metadata copied.dig(:items, defaults::DEFAULT_MAX_ARRAY_ITEMS, :_julewire_truncation),
                                        fields: ["array_items"],
                                        max_array_items: defaults::DEFAULT_MAX_ARRAY_ITEMS,
                                        max_hash_keys: defaults::DEFAULT_MAX_HASH_KEYS,
                                        max_string_bytes: defaults::DEFAULT_MAX_STRING_BYTES

      assert_equal defaults::DEFAULT_MAX_HASH_KEYS + 1, copied.fetch(:keys).length
      assert_symbol_truncation_metadata copied.dig(:keys, :_julewire_truncation),
                                        fields: ["hash_keys"],
                                        max_array_items: defaults::DEFAULT_MAX_ARRAY_ITEMS,
                                        max_hash_keys: defaults::DEFAULT_MAX_HASH_KEYS,
                                        max_string_bytes: defaults::DEFAULT_MAX_STRING_BYTES
      assert_false copied.fetch(:keys).key?(:"key_#{defaults::DEFAULT_MAX_HASH_KEYS}")

      assert_match(/\A#{"x" * defaults::DEFAULT_MAX_STRING_BYTES}\.\.\.\[Truncated\]\z/, copied.fetch(:body))
      assert_symbol_truncation_metadata copied.fetch(:_julewire_truncation),
                                        fields: %w[items keys body],
                                        max_array_items: defaults::DEFAULT_MAX_ARRAY_ITEMS,
                                        max_hash_keys: defaults::DEFAULT_MAX_HASH_KEYS,
                                        max_string_bytes: defaults::DEFAULT_MAX_STRING_BYTES
    end
  end
end
