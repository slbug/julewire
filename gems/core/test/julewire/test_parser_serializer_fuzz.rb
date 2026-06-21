# frozen_string_literal: true

require "test_helper"
require "json"

module Julewire
  class TestParserSerializerFuzz < Minitest::Test
    cover Julewire::Core::Serialization::Serializer

    SEED = 0x20260612
    ITERATIONS = 120
    TRUNCATED_SUFFIX = "...[Truncated]"
    TRUNCATION_METADATA_KEY = "_julewire_truncation"

    def test_serializer_outputs_json_safe_values_for_fixed_random_inputs
      random = Random.new(SEED)

      ITERATIONS.times do |index|
        with_fuzz_context("serializer", index) do
          value = random_value(random)

          serialized = Core::Serialization::Serializer.call(
            value,
            max_array_items: 8,
            max_depth: 5,
            max_hash_keys: 8,
            max_string_bytes: 64
          )

          JSON.generate(serialized, allow_nan: false)

          assert_bounded_serialized_value(
            serialized,
            max_array_items: 8,
            max_hash_keys: 8,
            max_string_bytes: 64
          )
        end
      end
    end

    def test_carrier_extract_returns_hash_for_fixed_random_inputs
      random = Random.new(SEED)

      ITERATIONS.times do |index|
        with_fuzz_context("carrier", index) do
          envelope = random_envelope(random)
          carrier = random_carrier(random, envelope)
          extracted = Core::Propagation::Carrier.extract(carrier)

          assert_kind_of Hash, extracted
          JSON.generate(Core::Serialization::Serializer.call(extracted), allow_nan: false)
        end
      end
    end

    private

    def with_fuzz_context(name, index)
      yield
    rescue StandardError => e
      flunk("#{name} fuzz seed=#{SEED} index=#{index}: #{e.class}: #{e.message}")
    end

    def assert_bounded_serialized_value(value, max_array_items:, max_hash_keys:, max_string_bytes:)
      case value
      when Array
        metadata = array_truncation_metadata(value)

        assert_operator value.length, :<=, max_array_items + (metadata ? 1 : 0)
        value.each { assert_bounded_serialized_value(it, max_array_items:, max_hash_keys:, max_string_bytes:) }
      when Hash
        metadata = value[TRUNCATION_METADATA_KEY]

        assert_operator value.length, :<=, max_hash_keys + (metadata ? 1 : 0)
        value.each_key { assert_bounded_string(it, max_string_bytes: max_string_bytes) }
        value.each_value { assert_bounded_serialized_value(it, max_array_items:, max_hash_keys:, max_string_bytes:) }
      when String

        assert_bounded_string(value, max_string_bytes: max_string_bytes)
      end
    end

    def array_truncation_metadata(value)
      tail = value.last
      tail[TRUNCATION_METADATA_KEY] if tail.is_a?(Hash)
    end

    def assert_bounded_string(value, max_string_bytes:)
      assert_predicate value, :valid_encoding?
      return if value.bytesize <= max_string_bytes

      assert value.end_with?(TRUNCATED_SUFFIX)
      assert_operator value.bytesize, :<=, max_string_bytes + TRUNCATED_SUFFIX.bytesize
    end

    def random_carrier(random, envelope)
      case random.rand(8)
      when 0 then nil
      when 1 then Object.new
      when 2 then {}
      when 3 then { julewire: random_string(random) }
      when 4 then { "julewire" => random_string(random) }
      when 5 then { "julewire" => JSON.generate(Core::Serialization::Serializer.call(envelope)) }
      when 6 then RaisingCarrier.new
      else { random_key(random) => random_value(random), "julewire" => random_json_fragment(random) }
      end
    end

    def random_envelope(random)
      {
        context: random_hash(random, depth: 0),
        carry: random_hash(random, depth: 0),
        execution: { type: "fuzz", id: random_string(random) }
      }
    end

    def random_value(random, depth: 0)
      return random_scalar(random) if depth >= 3

      case random.rand(10)
      when 0..4 then random_scalar(random)
      when 5..6 then random_array(random, depth: depth + 1)
      when 7..8 then random_hash(random, depth: depth + 1)
      else random_cycle(random)
      end
    end

    def random_scalar(random)
      case random.rand(4)
      when 0 then random_literal_scalar(random)
      when 1 then random_numeric_scalar(random)
      when 2 then random_string_scalar(random)
      else random_object_scalar(random)
      end
    end

    def random_literal_scalar(random)
      [nil, true, false].sample(random: random)
    end

    def random_numeric_scalar(random)
      [
        random.rand(-1_000..1_000),
        random.rand * 1_000,
        Float::NAN,
        Float::INFINITY,
        -Float::INFINITY
      ].sample(random: random)
    end

    def random_string_scalar(random)
      [random_string(random), random_invalid_utf8(random), random_key(random)].sample(random: random)
    end

    def random_object_scalar(random)
      return Time.at(random.rand(2_000_000_000), random.rand(1_000_000_000), :nanosecond).utc if random.rand(2).zero?

      ClassNameRaisingObject.new
    end

    def random_array(random, depth:)
      Array.new(random.rand(0..6)) { random_value(random, depth: depth) }
    end

    def random_hash(random, depth:)
      Array.new(random.rand(0..6)).to_h do
        [random_key(random), random_value(random, depth: depth)]
      end
    end

    def random_cycle(random)
      if random.rand(2).zero?
        array = []
        array << random_string(random)
        array << array
      else
        hash = {}
        hash[:self] = hash
        hash[random_key(random)] = random_string(random)
      end
    end

    def random_key(random)
      case random.rand(5)
      when 0 then random_string(random)
      when 1 then random_string(random).to_sym
      when 2 then random.rand(100)
      when 3 then random_invalid_utf8(random)
      else ClassNameRaisingObject.new
      end
    end

    def random_string(random)
      length = random.rand(0..40)
      Array.new(length) { random.rand(32..126).chr }.join
    end

    def random_invalid_utf8(random)
      bytes = Array.new(random.rand(1..10)) { random.rand(256) }
      bytes.pack("C*").force_encoding(Encoding::UTF_8)
    end

    def random_json_fragment(random)
      ["{", "[", random_string(random), JSON.generate("value" => random_string(random))].sample(random: random)
    end

    class ClassNameRaisingObject
      def class
        raise "class lookup failed"
      end
    end

    class RaisingCarrier
      def [](key)
        raise "cannot read #{key}"
      end
    end
  end
end
