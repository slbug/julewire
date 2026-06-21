# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestSerializerKeys < Minitest::Test
    cover Julewire::Core::Serialization::Serializer

    def test_serializer_duplicates_valid_utf8_string_keys
      key = +"tenant"
      serialized = Julewire::Core::Serialization::Serializer.call({ key => 1 })

      key << "-changed"

      assert_equal({ "tenant" => 1 }, serialized)
    end

    def test_serializer_serializes_symbol_hash_keys
      serialized = Julewire::Core::Serialization::Serializer.call({ tenant: 1 })

      assert_equal({ "tenant" => 1 }, serialized)
    end

    def test_serializer_sanitizes_non_utf8_symbol_hash_keys
      key = "tenant\xFF".b.to_sym
      serialized = Julewire::Core::Serialization::Serializer.call({ key => 1 })

      assert_equal 1, serialized.fetch("tenant?")
      assert_equal "{\"tenant?\":1}", JSON.generate(serialized)
    end

    def test_serializer_truncates_long_hash_keys
      key = "a" * (Julewire::Core::Serialization::Serializer::MAX_KEY_BYTES + 1)
      expected_key = "#{"a" * Julewire::Core::Serialization::Serializer::MAX_KEY_BYTES}...[Truncated]"
      serialized = Julewire::Core::Serialization::Serializer.call({ key => 1 })

      assert_equal 1, serialized.fetch(expected_key)
      assert_equal [expected_key], serialized.dig(
        "_julewire_truncation",
        "truncated_fields"
      )
    end

    def test_serializer_keeps_string_keys_at_exact_byte_limit_without_metadata
      key = "a" * Julewire::Core::Serialization::Serializer::MAX_KEY_BYTES
      serialized = Julewire::Core::Serialization::Serializer.call({ key => 1 })

      assert_equal 1, serialized.fetch(key)
      refute_includes serialized, "_julewire_truncation"
    end

    def test_serializer_truncates_long_symbol_hash_keys
      key = ("a" * (Julewire::Core::Serialization::Serializer::MAX_KEY_BYTES + 1)).to_sym
      expected_key = "#{"a" * Julewire::Core::Serialization::Serializer::MAX_KEY_BYTES}...[Truncated]"
      serialized = Julewire::Core::Serialization::Serializer.call({ key => 1 })

      assert_equal 1, serialized.fetch(expected_key)
      assert_equal [expected_key], serialized.dig(
        "_julewire_truncation",
        "truncated_fields"
      )
    end

    def test_serializer_keeps_symbol_keys_at_exact_byte_limit_without_metadata
      key = ("a" * Julewire::Core::Serialization::Serializer::MAX_KEY_BYTES).to_sym
      serialized = Julewire::Core::Serialization::Serializer.call({ key => 1 })

      assert_equal 1, serialized.fetch(key.name)
      refute_includes serialized, "_julewire_truncation"
    end

    def test_serializer_handles_integer_and_object_hash_keys
      object_key = Object.new
      def object_key.inspect
        "secret-key"
      end

      serialized = Julewire::Core::Serialization::Serializer.call({ 1 => "one", object_key => "object" })

      assert_equal "one", serialized["1"]
      assert_equal "object", serialized["[Object: Object]"]
      refute_includes serialized.keys.join, "secret-key"
    end
  end
end
