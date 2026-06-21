# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestBoundedTraversalHashLimits < Minitest::Test
    cover "Julewire::Core::Serialization::BoundedTraversal"
    cover Julewire::Core::Serialization::Serializer

    METADATA_KEY = Julewire::Core::Serialization::Serializer::TRUNCATION_METADATA_KEY

    def test_serializer_hash_key_limit_counts_input_entries_before_serialized_key_collisions
      value = colliding_key_hash

      serialized = Julewire::Core::Serialization::Serializer.call(value, max_hash_keys: 2)

      assert_equal 1, serialized.fetch("[Object: Object]")
      assert_string_truncation_metadata serialized.fetch(METADATA_KEY),
                                        fields: ["hash_keys"],
                                        max_hash_keys: 2
    end

    def test_serializer_compact_hash_key_limit_counts_input_entries_before_serialized_key_collisions
      value = colliding_key_hash

      serialized = Julewire::Core::Serialization::Serializer.call(value, compact_empty: true, max_hash_keys: 2)

      assert_equal 1, serialized.fetch("[Object: Object]")
      assert_string_truncation_metadata serialized.fetch(METADATA_KEY),
                                        fields: ["hash_keys"],
                                        max_hash_keys: 2
    end

    def test_serializer_hash_key_limit_does_not_process_post_limit_entries
      skipped_key = ExplodingKey.new("skipped")
      value = { first: 1, second: 2, skipped_key => "boom" }

      serialized = Julewire::Core::Serialization::Serializer.call(value, max_hash_keys: 2)

      assert_equal 1, serialized.fetch("first")
      assert_equal 2, serialized.fetch("second")
      assert_string_truncation_metadata serialized.fetch(METADATA_KEY),
                                        fields: ["hash_keys"],
                                        max_hash_keys: 2
    end

    def test_serializer_compact_hash_key_limit_does_not_process_post_limit_entries
      skipped_key = ExplodingKey.new("skipped")
      value = { nil_value: nil, first: 1, second: 2, skipped_key => "boom" }

      serialized = Julewire::Core::Serialization::Serializer.call(value, compact_empty: true, max_hash_keys: 3)

      assert_equal 1, serialized.fetch("first")
      assert_equal 2, serialized.fetch("second")
      assert_string_truncation_metadata serialized.fetch(METADATA_KEY),
                                        fields: ["hash_keys"],
                                        max_hash_keys: 3
    end

    def test_serializer_compact_array_item_limit_does_not_process_post_limit_entries
      skipped = CountingString.new("skipped")
      value = [nil, "first", "second", skipped]

      serialized = Julewire::Core::Serialization::Serializer.call(value, compact_empty: true, max_array_items: 3)

      assert_equal %w[first second], serialized.first(2)
      assert_string_truncation_metadata serialized.fetch(2).fetch(METADATA_KEY),
                                        fields: ["array_items"],
                                        max_array_items: 3
      assert_empty skipped.bytesize_calls
    end

    private

    def colliding_key_hash
      {}.tap { |value| 5.times { |index| value[Object.new] = index } }
    end

    class ExplodingKey < String
      def bytesize
        raise "post-limit key should not be serialized"
      end
    end

    class CountingString < String
      attr_reader :bytesize_calls

      def initialize(value)
        super
        @bytesize_calls = []
      end

      def bytesize
        @bytesize_calls << true
        super
      end
    end
  end
end
