# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestDeepCompactEmpty < Minitest::Test
    cover Julewire::Core::Serialization::DeepCompactEmpty

    def test_deep_compacts_nil_empty_hashes_and_empty_arrays
      value = {
        keep: "value",
        nil_value: nil,
        empty_hash: {},
        empty_array: [],
        nested: {
          remove: { child: nil },
          keep: { value: 1 }
        },
        array: [nil, {}, [], { remove: nil }, { keep: true }]
      }

      assert_equal(
        {
          keep: "value",
          nested: { keep: { value: 1 } },
          array: [{ keep: true }]
        },
        Julewire::Core.deep_compact_empty(value)
      )
    end

    def test_skips_raw_empty_containers_before_walking
      broken_empty_hash = Class.new(Hash) do
        def each
          raise "should not walk omitted empty hash"
        end
      end.new

      value = {
        keep: "value",
        skipped: broken_empty_hash,
        array: [nil, {}, [], { keep: true }]
      }

      assert_equal(
        {
          keep: "value",
          array: [{ keep: true }]
        },
        Julewire::Core.deep_compact_empty(value)
      )
    end

    def test_preserves_false_zero_and_empty_strings
      value = {
        false_value: false,
        zero: 0,
        empty_string: "",
        nested: [false, 0, ""]
      }

      assert_equal value, Julewire::Core.deep_compact_empty(value)
    end

    def test_does_not_mutate_input
      value = { empty_hash: {}, nested: { empty_array: [] } }

      Julewire::Core.deep_compact_empty(value)

      assert_equal({ empty_hash: {}, nested: { empty_array: [] } }, value)
    end

    def test_handles_cycles_without_recursing_forever
      value = {}
      value[:self] = value

      compacted = Julewire::Core.deep_compact_empty(value)

      assert_equal "[Circular]", compacted.fetch(:self)
    end

    def test_compact_owned_mutates_without_copying_kept_strings
      body = +"{\"ok\":true}"
      value = {
        web: {
          response_body: body,
          empty_hash: {},
          nested: [nil, { keep: body }, []]
        }
      }

      compacted = Julewire::Core::Serialization::DeepCompactEmpty.compact_owned!(value)

      assert_same value, compacted
      assert_same body, compacted.dig(:web, :response_body)
      assert_same body, compacted.dig(:web, :nested, 0, :keep)
      assert_equal({ web: { response_body: body, nested: [{ keep: body }] } }, compacted)
    end
  end
end
