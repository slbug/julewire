# frozen_string_literal: true

require "test_helper"
require "bigdecimal"

module Julewire
  class TestSerializerNumericTypes < Minitest::Test
    cover Julewire::Core::Serialization::Serializer

    def test_serializer_normalizes_big_decimal_as_fixed_string
      serialized = Julewire::Core::Serialization::Serializer.call({ big_decimal: BigDecimal("1.23") })

      assert_equal "1.23", serialized["big_decimal"]
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
  end
end
