# frozen_string_literal: true

require "test_helper"

module Julewire
  class RedactionLimitsTest < Minitest::Test
    cover Julewire::Redaction::Processor

    TRUNCATION_KEY = Julewire::Core::Serialization::Serializer::TRUNCATION_METADATA_KEY.to_sym

    def test_redaction_uses_shared_julewire_truncation_marker_spi_contract
      assert_julewire_truncation_marker_spi_contract
    end

    def test_redaction_bounds_nested_redaction_array_and_string_work
      payload = bounded_payload(
        Redaction::Processor.new(
          max_array_items: 1,
          max_depth: 5,
          max_hash_keys: 20,
          max_string_bytes: 18,
          string_values: true
        )
      )

      assert_equal(
        {
          token: "[FILTERED]",
          extra: "unvisited",
          secret: "[FILTERED]",
          array_marker: truncation_marker(
            ["array_items"],
            max_array_items: 1,
            max_depth: 5,
            max_hash_keys: 20,
            max_string_bytes: 18
          ),
          text: "access_token=[FILT...[Truncated]"
        },
        bounded_payload_summary(payload)
      )
    end

    def test_redaction_truncates_hashes_that_exceed_key_limit
      nested = 25.times.to_h { |index| [:"key_#{index}", index] }
      record = normalized_record(payload: { nested: nested })

      result = apply_redaction(Redaction::Processor.new(max_hash_keys: 20), record)

      assert_equal(
        truncation_marker(["hash_keys"], max_hash_keys: 20).fetch(TRUNCATION_KEY),
        result.dig(:payload, :nested, TRUNCATION_KEY)
      )
    end

    def test_redaction_does_not_truncate_record_envelope
      record = normalized_record(payload: { first: "one", second: "two" })

      result = apply_redaction(Redaction::Processor.new(max_hash_keys: 1), record)

      Core::Records::Record::REQUIRED_KEYS.each do |key|
        assert result.key?(key), "missing #{key}"
      end
      refute result.key?(TRUNCATION_KEY)
      assert_equal(
        truncation_marker(["hash_keys"], max_hash_keys: 1).fetch(TRUNCATION_KEY),
        result.dig(:payload, TRUNCATION_KEY)
      )
    end

    def test_redaction_rejects_invalid_traversal_limits
      assert_raises(ArgumentError) { Redaction::Processor.new(max_depth: 0) }
      assert_raises(ArgumentError) { Redaction::Processor.new(max_hash_keys: -1) }
    end

    private

    def bounded_payload(processor)
      record = normalized_record(
        payload: {
          keep: { access_token: "secret-token" },
          extra: "unvisited",
          list: [{ client_secret: "secret" }, { access_token: "later" }],
          text: "access_token=abcdefghijklmnopqrstuvwxyz"
        }
      )
      apply_redaction(processor, record).fetch(:payload)
    end

    def apply_redaction(processor, record)
      processor.call(Core::Records::Draft.from_record(record)).to_record
    end

    def bounded_payload_summary(payload)
      {
        token: payload.fetch(:keep).fetch(:access_token),
        extra: payload.fetch(:extra),
        secret: payload.fetch(:list).fetch(0).fetch(:client_secret),
        array_marker: payload.fetch(:list).fetch(1),
        text: payload.fetch(:text)
      }
    end

    def normalized_record(input = {})
      Core::Records::Draft.build(input, context: {}, scope: nil).to_record
    end

    def truncation_marker(fields, **limits)
      {
        TRUNCATION_KEY => Core::Serialization::Serializer.truncation_metadata(fields, **limits)
      }
    end
  end
end
