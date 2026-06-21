# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestFieldSetEmptyContainerContract < Minitest::Test
    cover Julewire::Core::Fields::FieldSet
    cover Julewire::Core::Serialization::ValueCopy

    def test_empty_containers_keep_public_copy_and_frozen_shapes
      assert_equal({}, Julewire::Core::Fields::FieldSet.deep_dup({}))
      assert_equal([], Julewire::Core::Fields::FieldSet.deep_dup([]))
      assert_equal({}, Julewire::Core::Fields::FieldSet.deep_symbolize_keys({}))
      assert_equal([], Julewire::Core::Fields::FieldSet.deep_symbolize_keys([]))

      assert_frozen_empty Julewire::Core::Fields::FieldSet.frozen_copy({})
      assert_frozen_empty Julewire::Core::Fields::FieldSet.frozen_copy([])
    end

    private

    def assert_frozen_empty(value)
      assert_empty value
      assert_predicate value, :frozen?
    end
  end
end
