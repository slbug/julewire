# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestRecordNormalizationBounds < Minitest::Test
    cover Julewire::Core::Records::Record

    def test_record_draft_build_bounds_deep_payload_normalization
      draft = Julewire::Core::Records::Draft.build(
        { payload: { nested: deep_hash(Julewire::Core::NORMALIZATION_MAX_DEPTH + 8) } },
        context: {},
        scope: nil
      )

      assert deep_value_contains?(draft.fetch(:payload), Julewire::Core::Serialization::Serializer::MAX_DEPTH_VALUE)
    end

    def test_record_finalization_bounds_deep_owned_mutation
      draft = Julewire::Core::Records::Draft.from_normalized_hash(normalized_record, freeze_sections: false)
      draft[:payload] = { nested: deep_hash(Julewire::Core::NORMALIZATION_MAX_DEPTH + 8) }

      record = draft.to_record

      assert deep_value_contains?(record.fetch(:payload), Julewire::Core::Serialization::Serializer::MAX_DEPTH_VALUE)
    end

    private

    def deep_hash(depth)
      depth.times.reduce("leaf") { |value, index| { "level_#{index}": value } }
    end

    def deep_value_contains?(value, expected)
      return true if value == expected
      return value.any? { deep_value_contains?(it, expected) } if value.is_a?(Array)
      return value.any? { |_, item| deep_value_contains?(item, expected) } if value.is_a?(Hash)

      false
    end
  end
end
