# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestRemoteSerializer < Minitest::Test
    REMOTE_SERIALIZER = Julewire::Ractor.const_get(:RemoteSerializer, false)
    private_constant :REMOTE_SERIALIZER

    cover "Julewire::Ractor::RemoteSerializer*"

    def test_serializes_bounded_payloads_without_changing_protocol_keys
      result = REMOTE_SERIALIZER.call(
        { payload: { blob: "abc" } },
        max_string_bytes: 1
      )

      assert_equal(
        {
          payload: {
            blob: "a...[Truncated]",
            _julewire_truncation: {
              truncated: true,
              truncated_fields: ["blob"],
              limits: {
                max_array_items: 1000,
                max_depth: 8,
                max_hash_keys: 1000,
                max_string_bytes: 1
              }
            }
          },
          _julewire_truncation: {
            truncated: true,
            truncated_fields: ["payload"],
            limits: {
              max_array_items: 1000,
              max_depth: 8,
              max_hash_keys: 1000,
              max_string_bytes: 1
            }
          }
        },
        result
      )
    end

    def test_rejects_string_keys_instead_of_normalizing_them
      error = assert_raises(TypeError) { REMOTE_SERIALIZER.call({ "payload" => true }) }

      assert_equal Julewire::Core::Fields::Internal::RECORD_STRING_KEY_ERROR, error.message
    end

    def test_rejects_non_symbol_keys_instead_of_stringifying_them
      error = assert_raises(TypeError) { REMOTE_SERIALIZER.call({ 1 => true }) }

      assert_equal Julewire::Core::Fields::Internal::RECORD_SYMBOL_KEY_ERROR, error.message
    end
  end
end
