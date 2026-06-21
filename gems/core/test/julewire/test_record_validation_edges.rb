# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestRecordValidationEdges < Minitest::Test
    cover Julewire::Core::Records::Record

    def test_record_from_normalized_hash_rejects_string_subclass_keys
      key = Class.new(String).new("payload")

      error = assert_raises(TypeError) do
        Julewire::Core::Records::Record.from_normalized_hash(normalized_record.merge(key => {}))
      end

      assert_equal "record must not use string keys", error.message
    end

    def test_record_from_normalized_hash_lists_multiple_unknown_top_level_keys
      error = assert_raises(TypeError) do
        Julewire::Core::Records::Record.from_normalized_hash(normalized_record.merge(tags: {}, debug: true))
      end

      assert_equal "record has unknown top-level keys: tags, debug", error.message
    end

    def test_record_from_normalized_hash_accepts_hash_subclasses
      hash = Class.new(Hash).new.merge!(normalized_record(payload: Class.new(Hash).new.merge!(id: 1)))

      record = Julewire::Core::Records::Record.from_normalized_hash(hash)

      assert_equal({ id: 1 }, record.fetch(:payload))
    end

    def test_record_from_normalized_hash_accepts_error_hash_subclasses
      error_hash = Class.new(Hash).new.merge!(class: "RuntimeError")

      record = Julewire::Core::Records::Record.from_normalized_hash(normalized_record(error: error_hash))

      assert_equal({ class: "RuntimeError" }, record.fetch(:error))
    end
  end
end
