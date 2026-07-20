# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestDeepCompactEmpty < Minitest::Test
    cover "Julewire::Core.deep_compact_empty"
    cover Julewire::Core::Serialization::DeepCompactEmpty
    cover "Julewire::Core::Serialization::ValueCopy#copy_array"
    cover "Julewire::Core::Serialization::ValueCopy#copy_container"
    cover "Julewire::Core::Serialization::ValueCopy#copy_hash"

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

    def test_deep_compact_empty_treats_container_subclasses_as_containers
      hash = Class.new(Hash).new
      array = Class.new(Array).new
      hash[:empty] = {}
      hash[:array] = array
      array.push(nil, { keep: true }, [])

      assert_equal({ array: [{ keep: true }] }, Julewire::Core.deep_compact_empty(hash))
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

      compacted = compact_owned(value)

      assert_same value, compacted
      assert_same body, compacted.dig(:web, :response_body)
      assert_same body, compacted.dig(:web, :nested, 0, :keep)
      assert_equal({ web: { response_body: body, nested: [{ keep: body }] } }, compacted)
    end

    def test_compact_owned_compacts_root_arrays_in_place
      first = { keep: 1 }
      second = { keep: 2 }
      value = [nil, first, {}, second, []]

      compacted = compact_owned(value)

      assert_same value, compacted
      assert_equal [first, second], compacted
      assert_same first, compacted.fetch(0)
      assert_same second, compacted.fetch(1)
    end

    def test_compact_owned_accepts_hash_subclasses
      value = Class.new(Hash).new
      value[:empty] = {}
      value[:keep] = { value: 1 }

      compacted = compact_owned(value)

      assert_same value, compacted
      assert_equal({ keep: { value: 1 } }, compacted)
    end

    def test_compact_owned_accepts_array_subclasses
      value = Class.new(Array).new
      value.push(nil, {}, { keep: 1 })

      compacted = compact_owned(value)

      assert_same value, compacted
      assert_equal [{ keep: 1 }], compacted
    end

    def test_compact_owned_compacts_nested_arrays_inside_root_arrays
      nested = [nil, { keep: 1 }, [], { keep: 2 }]
      value = [nested]

      compacted = compact_owned(value)

      assert_same value, compacted
      assert_same nested, compacted.fetch(0)
      assert_equal [{ keep: 1 }, { keep: 2 }], nested
    end

    def test_compact_owned_keeps_root_array_when_nothing_is_omitted
      first = { keep: 1 }
      second = { keep: 2 }
      value = [first, second]

      compacted = compact_owned(value)

      assert_same value, compacted
      assert_equal [first, second], compacted
      assert_same first, compacted.fetch(0)
      assert_same second, compacted.fetch(1)
    end

    def test_compact_owned_handles_root_array_cycles_without_copying_or_recursing
      value = [nil, { keep: true }]
      value << value

      compacted = compact_owned(value)

      assert_same value, compacted
      assert_true compacted.dig(0, :keep)
      assert_same value, compacted.fetch(1)
      assert_equal 2, compacted.length
    end

    def test_compact_owned_handles_cycles_without_copying_or_recursing
      value = { empty_hash: {} }
      value[:self] = value

      compacted = compact_owned(value)

      assert_same value, compacted
      assert_same value, compacted.fetch(:self)
      refute_includes compacted, :empty_hash
    end

    private

    def compact_owned(value)
      thread = safe_thread { Julewire::Core::Serialization::DeepCompactEmpty.compact_owned!(value) }

      safe_thread_value(thread, timeout: 0.1)
    end
  end
end
