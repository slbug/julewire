# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestFieldSet < Minitest::Test
    cover Julewire::Core::Fields::FieldSet

    def test_value_for_unknown_key_objects_does_not_call_to_sym
      fields = Array.new(32) { |index| [:"key#{index}", index] }.to_h
      key = Object.new

      def key.to_sym
        raise "should not symbolize"
      end

      assert_nil Julewire::Core::Fields::FieldSet.value_for(fields, key)
    end
  end
end
