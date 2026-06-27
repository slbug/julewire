# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestIntegrationProtocol < Minitest::Test
    cover Julewire::Core::Integration::Protocol

    def test_accepts_recursive_symbol_keyed_owned_data
      value = { payload: [{ message: "ok" }] }

      assert_same value, Julewire::Core::Integration::Protocol.validate_symbol_keys(value)
    end

    def test_rejects_string_keys
      error = assert_raises(TypeError) do
        Julewire::Core::Integration::Protocol.validate_symbol_keys(payload: { "message" => "bad" })
      end

      assert_equal Julewire::Core::Fields::Internal::RECORD_STRING_KEY_ERROR, error.message
    end

    def test_rejects_other_key_types
      error = assert_raises(TypeError) do
        Julewire::Core::Integration::Protocol.validate_symbol_keys(payload: { 1 => "bad" })
      end

      assert_equal Julewire::Core::Fields::Internal::RECORD_SYMBOL_KEY_ERROR, error.message
    end

    def test_symbol_hash_rejects_non_hash_owned_data
      error = assert_raises(TypeError) do
        Julewire::Core::Integration::Protocol.validate_symbol_hash([{ payload: :bad }])
      end

      assert_equal "owned data must be a Hash", error.message
    end

    def test_symbol_hash_returns_valid_owned_hash
      value = { payload: [{ message: "ok" }] }

      assert_same value, Julewire::Core::Integration::Protocol.validate_symbol_hash(value)
    end
  end
end
