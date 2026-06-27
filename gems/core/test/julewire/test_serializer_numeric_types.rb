# frozen_string_literal: true

require "test_helper"
require "bigdecimal"

module Julewire
  class TestSerializerNumericTypes < Minitest::Test
    cover Julewire::Core::Serialization::Serializer
    class FallbackNumeric < Numeric
      def initialize(value)
        super()
        @value = value
      end

      def to_s(*) = @value
    end

    def test_serializer_normalizes_big_decimal_as_fixed_string
      serialized = Julewire::Core::Serialization::Serializer.call({ big_decimal: BigDecimal("1.23") })

      assert_equal "1.23", serialized["big_decimal"]
    end

    def test_serializer_fallback_numeric_works_when_big_decimal_is_not_loaded
      big_decimal = Object.__send__(:remove_const, :BigDecimal)

      serialized = Julewire::Core::Serialization::Serializer.call(FallbackNumeric.new("123.45"))

      assert_equal "123.45", serialized
    ensure
      Object.const_set(:BigDecimal, big_decimal) if big_decimal
    end

    def test_serializer_normalizes_other_non_json_primitive_numerics
      serialized = Julewire::Core::Serialization::Serializer.call(
        {
          complex: Complex(1, 2),
          rational: Rational(1, 3)
        }
      )

      assert_equal "1+2i", serialized["complex"]
      assert_equal "1/3", serialized["rational"]
    end

    def test_serializer_bounds_fallback_numeric_strings
      serialized = Julewire::Core::Serialization::Serializer.call(
        { custom: FallbackNumeric.new("abcdef") },
        max_string_bytes: 3
      )

      assert_equal "abc...[Truncated]", serialized["custom"]
    end

    def test_serializer_sanitizes_fallback_numeric_strings
      invalid = +"bad\xFF"
      invalid.force_encoding(Encoding::UTF_8)

      serialized = Julewire::Core::Serialization::Serializer.call({ custom: FallbackNumeric.new(invalid) })

      assert_equal "bad?", serialized["custom"]
    end
  end
end
