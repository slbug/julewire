# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestDeepFreeze < Minitest::Test
    cover Julewire::Core::Serialization::DeepFreeze

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
  end
end
