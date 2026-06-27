# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestEncodingSanitizer < Minitest::Test
    cover "Julewire::Core::Serialization::EncodingSanitizer.call"
    cover Julewire::Core::Serialization::EncodingSanitizer
    def test_returns_valid_utf8_strings_as_is
      value = +"token"

      assert_same value, Julewire::Core::Serialization::EncodingSanitizer.call(value)
    end

    def test_returns_valid_string_subclasses_as_is
      value = Class.new(String).new("token")

      assert_same value, Julewire::Core::Serialization::EncodingSanitizer.call(value)
    end

    def test_returns_valid_non_ascii_utf8_strings_as_is
      value = +"café"

      assert_same value, Julewire::Core::Serialization::EncodingSanitizer.call(value)
    end

    def test_transcodes_non_utf8_strings
      value = +"caf\xE9"
      value.force_encoding(Encoding::ISO_8859_1)

      sanitized = Julewire::Core::Serialization::EncodingSanitizer.call(value)

      assert_equal "café", sanitized
      assert_equal Encoding::UTF_8, sanitized.encoding
    end

    def test_preserves_utf8_bytes_when_dummy_encoding_cannot_be_transcoded
      value = +"caf\xC3\xA9"
      value.force_encoding("UTF-7")

      sanitized = Julewire::Core::Serialization::EncodingSanitizer.call(value)

      assert_equal "café", sanitized
      assert_equal Encoding::UTF_8, sanitized.encoding
    end

    def test_returns_valid_ascii_only_strings_as_is
      value = +"2026-01-01T00:00:00Z"
      value.force_encoding(Encoding::US_ASCII)

      assert_same value, Julewire::Core::Serialization::EncodingSanitizer.call(value)
    end

    def test_scrubs_invalid_utf8_strings
      assert_invalid_utf8_repaired do |value|
        Julewire::Core::Serialization::EncodingSanitizer.call(value)
      end
    end

    def test_rejects_non_string_values
      assert_raises_message(TypeError, "value must be a String") do
        Julewire::Core::Serialization::EncodingSanitizer.call(Object.new)
      end
    end

    def test_rescue_path_repairs_invalid_bytes
      value = +"token \xE9"
      value.force_encoding(Encoding::ISO_8859_1)

      def value.encode(*)
        raise EncodingError, "broken"
      end

      def value.b
        +"token \xFF"
      end

      sanitized = Julewire::Core::Serialization::EncodingSanitizer.call(value)

      assert_equal "token ?", sanitized
      assert_predicate sanitized, :valid_encoding?
    end
  end
end
