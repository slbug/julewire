# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestSerializerKeys < Minitest::Test
    cover Julewire::Core::Serialization::Serializer
    class MutableKey < String; end

    def test_serializer_duplicates_valid_utf8_string_keys
      key = +"tenant"
      serialized = Julewire::Core::Serialization::Serializer.call({ key => 1 })

      key << "-changed"

      assert_equal({ "tenant" => 1 }, serialized)
    end

    def test_serializer_duplicates_mutable_string_subclass_keys
      key = MutableKey.new("tenant")
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

    def test_serializer_scrubs_partial_multibyte_truncated_hash_keys
      max_key_bytes = Julewire::Core::Serialization::Serializer::MAX_KEY_BYTES
      key = "#{"a" * (max_key_bytes - 1)}é"
      expected_key = "#{"a" * (max_key_bytes - 1)}?...[Truncated]"

      serialized = Julewire::Core::Serialization::Serializer.call({ key => 1 })

      assert_equal 1, serialized.fetch(expected_key)
      assert_predicate serialized.keys.fetch(0), :valid_encoding?
      assert_equal [expected_key], serialized.dig(
        "_julewire_truncation",
        "truncated_fields"
      )
    end

    def test_serializer_clears_key_truncation_state_for_following_normal_keys
      max_key_bytes = Julewire::Core::Serialization::Serializer::MAX_KEY_BYTES
      long_key = "a" * (max_key_bytes + 1)
      truncated_key = "#{"a" * max_key_bytes}...[Truncated]"
      serialized = Julewire::Core::Serialization::Serializer.call({ long_key => 1, "short" => 2 })

      assert_equal 1, serialized.fetch(truncated_key)
      assert_equal 2, serialized.fetch("short")
      assert_equal [truncated_key], serialized.dig(
        Julewire::Core::Serialization::Serializer::TRUNCATION_METADATA_KEY,
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

    def test_serializer_truncates_long_primitive_hash_keys
      max_key_bytes = Julewire::Core::Serialization::Serializer::MAX_KEY_BYTES
      key = 10**(max_key_bytes + 1)
      key_string = key.to_s
      expected_key = "#{key_string.byteslice(0, max_key_bytes)}...[Truncated]"

      serialized = Julewire::Core::Serialization::Serializer.call({ key => "number" })

      assert_equal "number", serialized.fetch(expected_key)
      assert_equal [expected_key], serialized.dig("_julewire_truncation", "truncated_fields")
    end

    def test_serializer_truncates_long_object_marker_hash_keys
      max_key_bytes = Julewire::Core::Serialization::Serializer::MAX_KEY_BYTES
      key_class = Class.new
      key_class.define_singleton_method(:name) { "ObjectName#{"x" * max_key_bytes}" }
      marker = "[Object: #{key_class.name}]"
      expected_key = "#{marker.byteslice(0, max_key_bytes)}...[Truncated]"

      serialized = Julewire::Core::Serialization::Serializer.call({ key_class.new => "object" })

      assert_equal "object", serialized.fetch(expected_key)
      assert_equal [expected_key], serialized.dig("_julewire_truncation", "truncated_fields")
    end
  end
end
