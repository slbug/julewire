# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestDeepFreeze < Minitest::Test
    cover "Julewire::Core::Serialization::DeepFreeze.call"
    cover "Julewire::Core::Serialization::DeepFreeze.validate_symbol_keys"
    cover "Julewire::Core::Serialization::DeepFreeze#call"
    cover "Julewire::Core::Serialization::DeepFreeze#depth_limited?"
    cover "Julewire::Core::Serialization::DeepFreeze#freeze_array"
    cover "Julewire::Core::Serialization::DeepFreeze#freeze_child"
    cover "Julewire::Core::Serialization::DeepFreeze#freeze_container"
    cover "Julewire::Core::Serialization::DeepFreeze#freeze_hash"
    cover "Julewire::Core::Serialization::DeepFreeze#freeze_value"
    cover "Julewire::Core::Serialization::DeepFreeze#initialize"

    def test_deep_freezes_hash_arrays_and_strings_in_place
      value = { "key" => [{ name: "value" }] }

      result = Julewire::Core::Serialization::DeepFreeze.call(value)

      assert_same value, result
      assert_predicate result, :frozen?
      assert_predicate result.keys.fetch(0), :frozen?
      assert_predicate result.fetch("key"), :frozen?
      assert_predicate result.dig("key", 0), :frozen?
      assert_predicate result.dig("key", 0, :name), :frozen?
    end

    def test_deep_freezes_root_strings_and_string_subclasses
      string = "value"
      string_subclass = Class.new(String).new("subclass")

      assert_same string, Julewire::Core::Serialization::DeepFreeze.call(string)
      assert_predicate string, :frozen?
      assert_same string_subclass, Julewire::Core::Serialization::DeepFreeze.call(string_subclass)
      assert_predicate string_subclass, :frozen?
    end

    def test_trusted_frozen_container_without_key_validation_skips_children
      child = []
      value = { child: child }.freeze

      result = Julewire::Core::Serialization::DeepFreeze.call(
        value,
        trust_frozen: true,
        validate_symbol_keys: false
      )

      assert_same value, result
      refute_predicate child, :frozen?
    end

    def test_trusted_frozen_container_without_key_validation_does_not_traverse
      hash_class = Class.new(Hash) do
        def each
          raise "unexpected traversal"
        end
      end
      value = hash_class.new
      value[:child] = []
      value.freeze

      result = Julewire::Core::Serialization::DeepFreeze.call(
        value,
        trust_frozen: true,
        validate_symbol_keys: false
      )

      assert_same value, result
    end

    def test_trust_frozen_does_not_skip_unfrozen_containers
      child = []
      value = { child: child }

      result = Julewire::Core::Serialization::DeepFreeze.call(value, trust_frozen: true)

      assert_same value, result
      assert_predicate value, :frozen?
      assert_predicate child, :frozen?
    end

    def test_frozen_container_without_trust_still_freezes_children
      child = []
      value = { child: child }.freeze

      result = Julewire::Core::Serialization::DeepFreeze.call(value, trust_frozen: false)

      assert_same value, result
      assert_predicate child, :frozen?
    end

    def test_default_does_not_trust_frozen_containers
      child = []
      value = { child: child }.freeze

      result = Julewire::Core::Serialization::DeepFreeze.call(value)

      assert_same value, result
      assert_predicate child, :frozen?
    end

    def test_deep_freezes_hash_and_array_subclasses
      hash_subclass = Class.new(Hash).new
      array_subclass = Class.new(Array).new
      hash_subclass[:array] = array_subclass

      result = Julewire::Core::Serialization::DeepFreeze.call(hash_subclass)

      assert_same hash_subclass, result
      assert_predicate hash_subclass, :frozen?
      assert_predicate array_subclass, :frozen?
    end

    def test_handles_hash_and_array_cycles
      hash = {}
      array = []
      hash[:self] = hash
      hash[:array] = array
      array << hash

      Julewire::Core::Serialization::DeepFreeze.call(hash)

      assert_predicate hash, :frozen?
      assert_predicate array, :frozen?
      assert_same hash, hash[:self]
      assert_same hash, array.fetch(0)
    end

    def test_replaces_containers_beyond_max_depth
      value = { payload: { nested: { value: "too deep" } } }

      result = Julewire::Core::Serialization::DeepFreeze.call(value, max_depth: 2)

      assert_equal Julewire::Core::Serialization::Serializer::MAX_DEPTH_VALUE, result.dig(:payload, :nested)
      assert_predicate result.fetch(:payload), :frozen?
    end

    def test_default_max_depth_bounds_deep_containers
      value = { payload: deep_hash(Julewire::Core::NORMALIZATION_MAX_DEPTH + 2) }

      result = Julewire::Core::Serialization::DeepFreeze.call(value)

      assert_true deep_value_contains?(result.fetch(:payload), Julewire::Core::Serialization::Serializer::MAX_DEPTH_VALUE)
    end

    def test_unfrozen_hash_validation_rejects_string_keys
      error = assert_raises(TypeError) do
        Julewire::Core::Serialization::DeepFreeze.call({ "bad" => true }, validate_symbol_keys: true)
      end

      assert_equal "record must not use string keys", error.message
    end

    def test_symbol_key_validation_checks_without_freezing
      value = { payload: { token: "secret" } }

      assert_same value, Julewire::Core::Serialization::DeepFreeze.validate_symbol_keys(value)
      refute_predicate value, :frozen?
      refute_predicate value.fetch(:payload), :frozen?
    end

    def test_symbol_key_validation_returns_scalars_unchanged
      value = Object.new

      assert_same value, Julewire::Core::Serialization::DeepFreeze.validate_symbol_keys(value)
    end

    def test_symbol_key_validation_tracks_containers_by_identity
      container_class = Class.new(Hash) do
        def eql?(_other) = true
        def hash = 0
      end
      value = [container_class[valid: true], container_class["invalid" => true]]

      error = assert_raises(TypeError) do
        Julewire::Core::Serialization::DeepFreeze.validate_symbol_keys(value)
      end

      assert_equal "record must not use string keys", error.message
    end

    def test_trusted_validation_ignores_frozen_scalars
      value = +"not a container"
      value.freeze

      assert_same value, Julewire::Core::Serialization::DeepFreeze.call(
        value,
        trust_frozen: true,
        validate_symbol_keys: true
      )
    end

    def test_trusted_validation_checks_symbol_keys_inside_pre_frozen_containers
      value = { ok: { "bad" => true }.freeze }.freeze

      error = assert_raises(TypeError) do
        Julewire::Core::Serialization::DeepFreeze.call(value, trust_frozen: true, validate_symbol_keys: true)
      end

      assert_equal "record must not use string keys", error.message
    end

    def test_trusted_validation_rejects_string_subclass_keys_as_string_keys
      key = Class.new(String).new("bad")
      value = { ok: { key => true }.freeze }.freeze

      error = assert_raises(TypeError) do
        Julewire::Core::Serialization::DeepFreeze.call(value, trust_frozen: true, validate_symbol_keys: true)
      end

      assert_equal "record must not use string keys", error.message
    end

    def test_trusted_validation_rejects_non_symbol_keys_inside_pre_frozen_containers
      value = { ok: { 42 => true }.freeze }.freeze

      error = assert_raises(TypeError) do
        Julewire::Core::Serialization::DeepFreeze.call(value, trust_frozen: true, validate_symbol_keys: true)
      end

      assert_equal "record keys must be Symbols", error.message
    end

    def test_trusted_validation_returns_original_container
      value = { ok: [:child].freeze }.freeze

      result = Julewire::Core::Serialization::DeepFreeze.call(
        value,
        trust_frozen: true,
        validate_symbol_keys: true
      )

      assert_same value, result
    end

    def test_trusted_validation_checks_keys_at_max_depth
      value = { ok: { "bad" => true }.freeze }.freeze

      error = assert_raises(TypeError) do
        Julewire::Core::Serialization::DeepFreeze.call(
          value,
          max_depth: 1,
          trust_frozen: true,
          validate_symbol_keys: true
        )
      end

      assert_equal "record must not use string keys", error.message
    end

    def test_trusted_validation_checks_keys_beyond_max_depth
      value = { ok: { nested: { "bad" => true }.freeze }.freeze }.freeze

      error = assert_raises(TypeError) do
        Julewire::Core::Serialization::DeepFreeze.call(
          value,
          max_depth: 2,
          trust_frozen: true,
          validate_symbol_keys: true
        )
      end

      assert_equal "record must not use string keys", error.message
    end

    def test_trusted_validation_checks_root_at_zero_max_depth
      value = { "bad" => true }.freeze

      error = assert_raises(TypeError) do
        Julewire::Core::Serialization::DeepFreeze.call(
          value,
          max_depth: 0,
          trust_frozen: true,
          validate_symbol_keys: true
        )
      end

      assert_equal "record must not use string keys", error.message
    end

    def test_trusted_validation_tracks_cycles
      value = {}
      value[:self] = value
      value.freeze

      result = Julewire::Core::Serialization::DeepFreeze.call(
        value,
        trust_frozen: true,
        validate_symbol_keys: true
      )

      assert_same value, result
      assert_same value, result.fetch(:self)
    end

    def test_trusted_validation_tracks_cycles_without_depth_limit
      value = {}
      value[:self] = value
      value.freeze

      result = Julewire::Core::Serialization::DeepFreeze.call(
        value,
        max_depth: nil,
        trust_frozen: true,
        validate_symbol_keys: true
      )

      assert_same value, result
      assert_same value, result.fetch(:self)
    end

    def test_trusted_validation_checks_arrays_inside_pre_frozen_containers
      value = [{ "bad" => true }.freeze].freeze

      error = assert_raises(TypeError) do
        Julewire::Core::Serialization::DeepFreeze.call(value, trust_frozen: true, validate_symbol_keys: true)
      end

      assert_equal "record must not use string keys", error.message
    end

    def test_trusted_validation_checks_arrays_nested_inside_pre_frozen_hashes
      value = { items: [{ "bad" => true }.freeze].freeze }.freeze

      error = assert_raises(TypeError) do
        Julewire::Core::Serialization::DeepFreeze.call(value, trust_frozen: true, validate_symbol_keys: true)
      end

      assert_equal "record must not use string keys", error.message
    end

    def test_trusted_validation_checks_hash_subclasses_nested_inside_pre_frozen_hashes
      child = Class.new(Hash).new
      child["bad"] = true
      child.freeze
      value = { child: child }.freeze

      error = assert_raises(TypeError) do
        Julewire::Core::Serialization::DeepFreeze.call(value, trust_frozen: true, validate_symbol_keys: true)
      end

      assert_equal "record must not use string keys", error.message
    end

    def test_trusted_validation_checks_array_subclasses_nested_inside_pre_frozen_hashes
      child = Class.new(Array).new([{ "bad" => true }.freeze])
      child.freeze
      value = { items: child }.freeze

      error = assert_raises(TypeError) do
        Julewire::Core::Serialization::DeepFreeze.call(value, trust_frozen: true, validate_symbol_keys: true)
      end

      assert_equal "record must not use string keys", error.message
    end

    def test_trusted_validation_does_not_freeze_array_children
      child = []
      value = [child].freeze

      result = Julewire::Core::Serialization::DeepFreeze.call(value, trust_frozen: true, validate_symbol_keys: true)

      assert_same value, result
      refute_predicate child, :frozen?
    end

    def test_trusted_validation_does_not_freeze_array_subclass_children
      array = Class.new(Array).new
      child = []
      array << child
      array.freeze

      result = Julewire::Core::Serialization::DeepFreeze.call(array, trust_frozen: true, validate_symbol_keys: true)

      assert_same array, result
      refute_predicate child, :frozen?
    end

    def test_trusted_validation_checks_hash_subclasses
      hash = Class.new(Hash).new
      hash["bad"] = true
      hash.freeze

      error = assert_raises(TypeError) do
        Julewire::Core::Serialization::DeepFreeze.call(hash, trust_frozen: true, validate_symbol_keys: true)
      end

      assert_equal "record must not use string keys", error.message
    end

    def test_trusted_validation_does_not_freeze_hash_subclass_children
      hash = Class.new(Hash).new
      child = []
      hash[:child] = child
      hash.freeze

      result = Julewire::Core::Serialization::DeepFreeze.call(hash, trust_frozen: true, validate_symbol_keys: true)

      assert_same hash, result
      refute_predicate child, :frozen?
    end

    def test_trusted_validation_returns_original_for_custom_each_result
      hash_class = Class.new(Hash) do
        def each(&)
          super
          :custom_result
        end
      end
      hash = hash_class.new
      hash[:ok] = true
      hash.freeze

      result = Julewire::Core::Serialization::DeepFreeze.call(hash, trust_frozen: true, validate_symbol_keys: true)

      assert_same hash, result
    end

    private

    def deep_hash(depth)
      depth.times.reduce({ value: "leaf" }) { |child, _| { nested: child } }
    end

    def deep_value_contains?(value, expected)
      current = value
      loop do
        return true if current == expected
        return false unless current.is_a?(Hash)

        current = current[:nested]
      end
    end
  end

  class TestValidateSymbolHash < Minitest::Test
    cover "Julewire::Core::Serialization::DeepFreeze.validate_symbol_hash"

    def test_returns_the_same_symbol_keyed_hash_without_freezing_it
      value = { payload: [{ id: "one" }] }

      assert_same value, Julewire::Core::Serialization::DeepFreeze.validate_symbol_hash(value)
      refute_predicate value, :frozen?
    end

    def test_accepts_hash_subclasses
      value = Class.new(Hash)[payload: { id: "one" }]

      assert_same value, Julewire::Core::Serialization::DeepFreeze.validate_symbol_hash(value)
    end

    def test_rejects_non_hash_input_loudly
      error = assert_raises(TypeError) do
        Julewire::Core::Serialization::DeepFreeze.validate_symbol_hash([:not_a_hash])
      end

      assert_equal "owned data must be a Hash", error.message
    end

    def test_rejects_nested_string_keys_loudly
      error = assert_raises(TypeError) do
        Julewire::Core::Serialization::DeepFreeze.validate_symbol_hash(payload: [{ "id" => "one" }])
      end

      assert_equal Julewire::Core::Fields::Internal::RECORD_STRING_KEY_ERROR, error.message
    end
  end
end
