# frozen_string_literal: true

require "test_helper"
require "json"

module Julewire
  class TestCarrierExtractionContracts < Minitest::Test
    cover "Julewire::Core::ContextStore#with_propagation"
    cover Julewire::Core::Propagation::Carrier
    cover "Julewire::Core::Propagation::Carrier.carrier_value"
    cover "Julewire::Core::Propagation::Carrier.restore"
    def test_extract_ignores_invalid_payloads
      assert_empty Core::Propagation::Carrier.extract_envelope({ "julewire" => "{" })
      assert_empty Core::Propagation::Carrier.extract_envelope({ "julewire" => "[]" })
    end

    def test_extract_result_reports_invalid_payload_status
      assert_extract_failure_status("{",
                                    :malformed,
                                    "carrier payload is not valid JSON",
                                    extraction_error: true)
    end

    def test_extract_result_returns_public_extracted_spi_object
      payload = JSON.generate("context" => { "request_id" => "request-1" })

      result = Core::Propagation::Carrier.extract_result({ "julewire" => payload })

      assert_instance_of Core::Propagation::Carrier::Extracted, result
      assert_equal :ok, result.status
      assert_nil result.reason
      assert_nil result.error
      refute_predicate result, :failure?
      assert_equal "request-1", result.envelope.dig(:context, :request_id)
    end

    def test_extract_result_reports_missing_payload_status_without_failure
      result = Core::Propagation::Carrier.extract_result({})

      assert_empty result.envelope
      assert_equal :missing, result.status
      assert_nil result.reason
      assert_nil result.error
      refute_predicate result, :failure?
    end

    def test_extract_stringifies_carrier_values
      payload = JSON.generate("context" => { "request_id" => "request-1" })
      carrier = { "julewire" => StringishCarrierPayload.new(payload) }

      envelope = Core::Propagation::Carrier.extract_envelope(carrier)

      assert_equal "request-1", envelope.dig(:context, :request_id)
    end

    def test_extract_result_reports_non_hash_payload_status
      assert_extract_failure_status("[1,2,3]",
                                    :non_hash,
                                    "carrier payload must be a JSON object",
                                    extraction_error: true)
    end

    def test_extract_ignores_oversized_payload_before_parsing
      payload = JSON.generate("context" => { "request_id" => "request-1" })

      assert_empty Core::Propagation::Carrier.extract_envelope(
        { "julewire" => payload },
        max_bytes: payload.bytesize - 1
      )
    end

    def test_extract_defaults_to_carrier_byte_limit
      payload = JSON.generate("context" => { "blob" => "x" * Core::Propagation::Carrier::DEFAULT_MAX_BYTES })

      assert_empty Core::Propagation::Carrier.extract_envelope({ "julewire" => payload })
    end

    def test_extract_allows_explicit_unbounded_raw_payload_limit
      payload = JSON.generate("context" => { "blob" => "x" * Core::Propagation::Carrier::DEFAULT_MAX_BYTES })

      envelope = Core::Propagation::Carrier.extract_envelope({ "julewire" => payload }, max_bytes: nil)

      assert_match(/\Ax+\.\.\.\[Truncated\]\z/, envelope.dig(:context, :blob))
    end

    def test_extract_accepts_payload_at_exact_max_bytes_limit
      payload = JSON.generate("context" => { "request_id" => "request-1" })

      envelope = Core::Propagation::Carrier.extract_envelope({ "julewire" => payload }, max_bytes: payload.bytesize)

      assert_equal "request-1", envelope.dig(:context, :request_id)
    end

    def test_extract_result_reports_oversized_payload_status
      payload = JSON.generate("context" => { "request_id" => "request-1" })

      assert_extract_failure_status(payload,
                                    :oversized,
                                    "carrier payload exceeds max_bytes",
                                    max_bytes: payload.bytesize - 1)
    end

    def test_restore_ignores_oversized_payload
      payload = JSON.generate("context" => { "request_id" => "request-1" })
      carrier = { "julewire" => payload }

      observed = Core::Propagation::Carrier.restore(carrier, max_bytes: payload.bytesize - 1) do
        Julewire.context.to_h
      end

      assert_empty observed
    end

    def test_restore_defaults_to_carrier_byte_limit
      payload = JSON.generate("context" => { "blob" => "x" * Core::Propagation::Carrier::DEFAULT_MAX_BYTES })
      carrier = { "julewire" => payload }

      observed = Core::Propagation::Carrier.restore(carrier) { Julewire.context.to_h }

      assert_empty observed
    end

    def test_restore_accepts_payload_at_exact_max_bytes_limit
      payload = JSON.generate("context" => { "request_id" => "request-1" })
      carrier = { "julewire" => payload }

      observed = Core::Propagation::Carrier.restore(carrier, max_bytes: payload.bytesize) do
        Julewire.context.to_h
      end

      assert_equal({ request_id: "request-1" }, observed)
    end

    def test_restore_preserves_julewire_truncation_metadata
      encoded = Core::Propagation::Carrier.encode(envelope: { context: { blob: "x" * 20_000 } })
      carrier = { "julewire" => encoded }

      observed = Core::Propagation::Carrier.restore(carrier) { Julewire.context.to_h }

      assert_match(/\Ax+\.\.\.\[Truncated\]\z/, observed.fetch(:blob))
      assert_symbol_truncation_metadata observed.fetch(:_julewire_truncation),
                                        fields: ["blob"],
                                        max_string_bytes: Core::Serialization::Serializer::DEFAULT_MAX_STRING_BYTES
    end

    def test_extract_validates_max_bytes
      error = assert_raises(ArgumentError) do
        Core::Propagation::Carrier.extract_envelope({}, max_bytes: 0)
      end

      assert_equal "max_bytes must be nil or a positive Integer", error.message
    end

    private

    def assert_extract_failure_status(payload, status, reason, max_bytes: nil, extraction_error: false)
      options = {}
      options[:max_bytes] = max_bytes unless max_bytes.nil?
      result = Core::Propagation::Carrier.extract_result({ "julewire" => payload }, **options)

      assert_empty result.envelope
      assert_predicate result, :failure?
      assert_equal status, result.status
      assert_equal reason, result.reason
      assert_instance_of Core::Propagation::Carrier::ExtractionError, result.error if extraction_error
      assert_equal reason, result.error.reason if extraction_error
      refute_nil result.error.backtrace if status == :malformed
    end

    class StringishCarrierPayload
      def initialize(value)
        @value = value
      end

      def to_s = @value
    end
  end
end
