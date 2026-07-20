# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestBuildInput < Minitest::Test
    cover "Julewire::Core::Records::BuildInput*"

    def test_public_input_normalizes_empty_and_scalar_shapes
      scalar = Object.new
      scalar.define_singleton_method(:to_s) { "scalar message" }

      assert_equal({}, build_input.normalize_public(nil))
      assert_equal({ message: "scalar message" }, build_input.normalize_public(scalar))
      assert_equal({ message: "saved" }, build_input.normalize_public(message: "saved"))
    end

    def test_public_input_separates_record_fields_from_payload_fields
      normalized = build_input.normalize_public(
        "message" => "saved",
        "attempt" => 2,
        "payload" => { "attempt" => 3, "token" => "kept" }
      )

      assert_equal "saved", normalized.fetch(:message)
      assert_equal({ attempt: 3, token: "kept" }, normalized.fetch(:payload))
    end

    def test_public_input_wraps_scalar_payload_before_merging_unknown_fields
      normalized = build_input.normalize_public(payload: "raw", attempt: 2)

      assert_equal({ value: "raw", attempt: 2 }, normalized.fetch(:payload))
    end

    def test_public_input_marks_direct_record_cycles
      input = {}
      input["message"] = input
      input["attempt"] = input

      normalized = build_input.normalize_public(input)

      assert_equal Core::CIRCULAR_REFERENCE, normalized.fetch(:message)
      assert_equal({ attempt: Core::CIRCULAR_REFERENCE }, normalized.fetch(:payload))
    end

    def test_owned_input_requires_a_hash_and_preserves_hash_subclasses
      error = assert_raises(TypeError) { build_input.validate_owned("owned") }
      input = Class.new(Hash).new.merge!(message: "owned")

      assert_equal "owned record input must be a Hash", error.message
      assert_same input, build_input.validate_owned(input)
    end

    def test_owned_input_rejects_recursive_non_symbol_keys
      string_error = assert_raises(TypeError) do
        build_input.validate_owned(payload: { "token" => "secret" })
      end
      object_error = assert_raises(TypeError) do
        build_input.validate_owned(payload: { Object.new => "secret" })
      end

      assert_equal "record must not use string keys", string_error.message
      assert_equal "record keys must be Symbols", object_error.message
    end

    def test_owned_input_lists_unknown_top_level_fields
      error = assert_raises(TypeError) do
        build_input.validate_owned(message: "owned", custom: true, debug: true)
      end

      assert_equal "owned record input has unknown top-level keys: custom, debug", error.message
    end

    private

    def build_input = Julewire::Core::Records::BuildInput
  end
end
