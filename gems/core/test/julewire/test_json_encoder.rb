# frozen_string_literal: true

require "test_helper"
require "json"

module Julewire
  class TestJsonEncoder < Minitest::Test
    cover "Julewire::Core::Serialization::EncodingSanitizer.call"
    cover Julewire::Core::Serialization::JsonEncoder
    cover "Julewire::Core::Serialization::JsonEncoder#initialize"
    cover Julewire::Core::Serialization::SerializerPool
    class CountingJsonEncoder < Julewire::Core::Serialization::JsonEncoder
      attr_reader :serializer_build_count

      private

      def build_serializer
        @serializer_build_count = @serializer_build_count.to_i + 1
        super
      end
    end

    class ReentrantJsonEncoder < Julewire::Core::Serialization::JsonEncoder
      private

      def build_serializer
        ReentrantSerializer.new(self)
      end
    end

    class ReentrantSerializer < Julewire::Core::Serialization::Serializer
      def initialize(encoder)
        @encoder = encoder
        super()
      end

      def serialize(value)
        raise "cached serializer was reused while busy" if @in_use

        @in_use = true
        if value.is_a?(Hash) && value.key?(:reenter)
          nested = JSON.parse(@encoder.call(nested: value.fetch(:reenter)))
          return super(value.merge(nested: nested).except(:reenter))
        end
        super
      ensure
        @in_use = false
      end
    end

    class NamedSerializer
      def initialize(name)
        @name = name
      end

      def in_use? = false

      def serialize(_payload) = @name
    end

    def test_serializes_mutable_strings_without_mutating_them
      value = +"value"
      encoded = Julewire::Core::Serialization::JsonEncoder.new.call({ message: value })

      value << "-changed"

      assert_equal({ "message" => "value" }, JSON.parse(encoded))
      assert_equal "value-changed", value
    end

    def test_appends_newline_by_default
      encoded = Julewire::Core::Serialization::JsonEncoder.new.call(message: "hello")

      assert_equal "\n", encoded[-1]
      assert_equal({ "message" => "hello" }, JSON.parse(encoded))
    end

    def test_can_emit_without_trailing_newline
      encoded = Julewire::Core::Serialization::JsonEncoder.new(append_newline: false).call(message: "hello")

      assert_false encoded.end_with?("\n")
      assert_equal({ "message" => "hello" }, JSON.parse(encoded))
    end

    def test_keeps_serializer_cache_thread_local
      encoder = Julewire::Core::Serialization::JsonEncoder.new
      thread = safe_thread do
        encoder.call(message: "hello")
        Thread.current.thread_variable_get(:julewire_core_json_encoder_serializers).size
      end

      assert_equal 1, safe_thread_value(thread)
      assert_false encoder.instance_variable_defined?(:@serializers)
    end

    def test_serializer_pool_keeps_distinct_serializer_keys
      pool_key = :julewire_core_serializer_pool_test

      with_clean_thread_pool(pool_key) do
        first = Julewire::Core::Serialization::SerializerPool.serialize(pool_key, :first, :payload) do
          NamedSerializer.new(:first)
        end
        second = Julewire::Core::Serialization::SerializerPool.serialize(pool_key, :second, :payload) do
          NamedSerializer.new(:second)
        end

        assert_equal :first, first
        assert_equal :second, second
      end
    end

    def test_honors_non_default_compact_empty_option
      encoder = Julewire::Core::Serialization::JsonEncoder.new(compact_empty: false)

      encoded = JSON.parse(encoder.call(payload: { empty_hash: {}, empty_array: [] }))

      assert_equal({ "payload" => { "empty_hash" => {}, "empty_array" => [] } }, encoded)
    end

    def test_compacts_empty_values_by_default
      encoder = Julewire::Core::Serialization::JsonEncoder.new

      encoded = JSON.parse(encoder.call(payload: { empty_hash: {}, empty_array: [], keep: true }))

      assert_equal({ "payload" => { "keep" => true } }, encoded)
    end

    def test_honors_custom_backtrace_limit
      error = RuntimeError.new("boom")
      error.set_backtrace(%w[first second])
      encoder = Julewire::Core::Serialization::JsonEncoder.new(max_backtrace_lines: 1)

      encoded = JSON.parse(encoder.call(error: error))

      assert_equal ["first"], encoded.dig("error", "backtrace")
    end

    def test_non_default_encoder_uses_distinct_thread_local_pool_entry
      with_clean_serializer_pool do
        default_encoder = Julewire::Core::Serialization::JsonEncoder.new
        custom_encoder = Julewire::Core::Serialization::JsonEncoder.new(compact_empty: false)

        default_encoder.call(message: "default")
        custom_encoder.call(payload: { empty_hash: {} })

        pool = Thread.current.thread_variable_get(:julewire_core_json_encoder_serializers)

        assert_equal 2, pool.size
      end
    end

    def test_serializer_pool_key_includes_array_limit
      with_clean_serializer_pool do
        default_encoder = Julewire::Core::Serialization::JsonEncoder.new(append_newline: false)
        limited_encoder = Julewire::Core::Serialization::JsonEncoder.new(
          max_array_items: 1,
          append_newline: false
        )

        default_encoded = JSON.parse(default_encoder.call(%w[one two]))
        limited_encoded = JSON.parse(limited_encoder.call(%w[one two]))

        assert_equal %w[one two], default_encoded
        assert_equal "one", limited_encoded.fetch(0)
        assert_equal ["array_items"], limited_encoded.fetch(1).dig("_julewire_truncation", "truncated_fields")
      end
    end

    def test_serializer_pool_key_includes_backtrace_limit
      with_clean_serializer_pool do
        error = RuntimeError.new("boom")
        error.set_backtrace(%w[first second])
        default_encoder = Julewire::Core::Serialization::JsonEncoder.new(append_newline: false)
        limited_encoder = Julewire::Core::Serialization::JsonEncoder.new(
          max_backtrace_lines: 1,
          append_newline: false
        )

        default_encoded = JSON.parse(default_encoder.call(error: error))
        limited_encoded = JSON.parse(limited_encoder.call(error: error))

        assert_equal %w[first second], default_encoded.dig("error", "backtrace")
        assert_equal ["first"], limited_encoded.dig("error", "backtrace")
      end
    end

    def test_non_default_encoder_reuses_thread_local_serializer
      with_clean_serializer_pool do
        encoder = CountingJsonEncoder.new(compact_empty: false)

        encoder.call(message: "first")
        encoder.call(message: "second")

        assert_equal 1, encoder.serializer_build_count
      end
    end

    def test_default_encoder_reuses_thread_local_serializer
      with_clean_serializer_pool do
        encoder = CountingJsonEncoder.new

        encoder.call(message: "first")
        encoder.call(message: "second")

        assert_equal 1, encoder.serializer_build_count
      end
    end

    def test_non_default_encoder_uses_fallback_serializer_when_cached_serializer_is_busy
      with_clean_serializer_pool do
        encoder = ReentrantJsonEncoder.new(max_backtrace_lines: 1)

        encoded = JSON.parse(encoder.call(reenter: Float::INFINITY))

        assert_equal({ "nested" => { "nested" => "Infinity" } }, encoded)
      end
    end

    def test_default_encoder_uses_fallback_serializer_when_cached_serializer_is_busy
      with_clean_serializer_pool do
        encoder = ReentrantJsonEncoder.new

        encoded = JSON.parse(encoder.call(reenter: Float::INFINITY))

        assert_equal({ "nested" => { "nested" => "Infinity" } }, encoded)
      end
    end

    def test_honors_custom_depth_limit
      encoder = Julewire::Core::Serialization::JsonEncoder.new(max_depth: 1, append_newline: false)
      encoded = JSON.parse(encoder.call(payload: { nested: true }))

      assert_equal "[MaxDepth]", encoded.fetch("payload")
      assert_equal ["payload"], encoded.dig("_julewire_truncation", "truncated_fields")
    end

    def test_honors_custom_string_limit
      encoder = Julewire::Core::Serialization::JsonEncoder.new(max_string_bytes: 3, append_newline: false)

      assert_equal "abc...[Truncated]", JSON.parse(encoder.call("abcdef"))
    end

    def test_honors_custom_array_limit
      encoder = Julewire::Core::Serialization::JsonEncoder.new(max_array_items: 1, append_newline: false)
      encoded = JSON.parse(encoder.call(%w[one two]))

      assert_equal "one", encoded.fetch(0)
      assert_equal ["array_items"], encoded.fetch(1).dig("_julewire_truncation", "truncated_fields")
    end

    def test_honors_custom_hash_limit
      encoder = Julewire::Core::Serialization::JsonEncoder.new(max_hash_keys: 1, append_newline: false)
      encoded = JSON.parse(encoder.call(a: 1, b: 2))

      assert_equal 1, encoded.fetch("a")
      assert_equal ["hash_keys"], encoded.dig("_julewire_truncation", "truncated_fields")
    end

    private

    def with_clean_thread_pool(key)
      previous = Thread.current.thread_variable_get(key)
      Thread.current.thread_variable_set(key, nil)
      yield
    ensure
      Thread.current.thread_variable_set(key, previous)
    end

    def with_clean_serializer_pool(&)
      with_clean_thread_pool(:julewire_core_json_encoder_serializers, &)
    end
  end
end
