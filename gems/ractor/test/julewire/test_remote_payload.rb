# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestRactorRemotePayload < Minitest::Test
    cover Julewire::Ractor::RemotePayload
    cover "Julewire::Ractor::RemotePayload.hash_value"
    cover "Julewire::Ractor::RemotePayload.scope_snapshot"

    def test_extracts_symbol_keyed_owned_sections
      payload = Julewire::Ractor::RemotePayload.extract(
        input: { message: "done" },
        context: { request_id: "r1" },
        neutral: { "messaging.system": "kafka" },
        attributes: { ractor: { child: true } },
        carry: { traceparent: "trace-1" },
        scope: { execution: {}, neutral: {}, attributes: {}, carry: {}, labels: {} }
      )

      assert_equal({ message: "done" }, payload.fetch(:input))
      assert_equal({ request_id: "r1" }, payload.fetch(:context))
      assert_equal({ "messaging.system": "kafka" }, payload.fetch(:neutral))
      assert_equal({ ractor: { child: true } }, payload.fetch(:attributes))
      assert_equal({ traceparent: "trace-1" }, payload.fetch(:carry))
    end

    def test_extracts_owned_scope_snapshot
      payload = Julewire::Ractor::RemotePayload.extract(
        input: {},
        context: {},
        neutral: {},
        attributes: {},
        carry: {},
        scope: {
          execution: { type: "ractor", id: "child-1" },
          neutral: { "messaging.system": "kafka" },
          attributes: { ractor: { child: true } },
          carry: { traceparent: "trace-1" },
          labels: { worker: "child" }
        }
      )
      scope = payload.fetch(:scope)

      assert_instance_of Julewire::Core::Execution::ScopeSnapshot, scope
      assert_equal({ type: "ractor", id: "child-1" }, scope.execution_hash)
      assert_equal({ "messaging.system": "kafka" }, scope.neutral_hash)
      assert_equal({ ractor: { child: true } }, scope.attributes_hash)
      assert_equal({ traceparent: "trace-1" }, scope.carry_hash)
      assert_equal({ worker: "child" }, scope.labels_hash)
    end

    def test_rejects_malformed_protocol_instead_of_defaulting_sections
      valid = valid_payload

      assert_raises(TypeError) { Julewire::Ractor::RemotePayload.extract("not a hash") }
      assert_raises(KeyError) { Julewire::Ractor::RemotePayload.extract(valid.except(:context)) }
      assert_raises(TypeError) { Julewire::Ractor::RemotePayload.extract(valid.merge(context: [])) }
      assert_raises(TypeError) { Julewire::Ractor::RemotePayload.extract(valid.merge("context" => {})) }
      assert_raises(TypeError) do
        Julewire::Ractor::RemotePayload.extract(valid.merge(context: { "request_id" => "r1" }))
      end
    end

    def test_preserves_owned_truncation_metadata
      payload = Julewire::Ractor::RemotePayload.extract(
        valid_payload.merge(
          context: {
            _julewire_truncation: {
              truncated: true,
              truncated_fields: ["blob"],
              limits: { max_string_bytes: 16_384 }
            }
          }
        )
      )
      metadata = payload.dig(:context, :_julewire_truncation)

      assert_true metadata.fetch(:truncated)
      assert_equal ["blob"], metadata.fetch(:truncated_fields)
      assert_equal 16_384, metadata.dig(:limits, :max_string_bytes)
    end

    private

    def valid_payload
      {
        input: {},
        context: {},
        neutral: {},
        attributes: {},
        carry: {},
        scope: { execution: {}, neutral: {}, attributes: {}, carry: {}, labels: {} }
      }
    end
  end
end
