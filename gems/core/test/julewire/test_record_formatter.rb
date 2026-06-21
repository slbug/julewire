# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestRecordFormatter < Minitest::Test
    def test_default_formatter_omits_internal_and_empty_fields
      record = build_record(
        { message: "hello", logger: nil, payload: {}, labels: { service: "core" } },
        context: {},
        carry: { http: { request_headers: { traceparent: "trace-1" } } },
        scope: nil
      )

      formatted = formatted_record(record)

      assert_equal "hello", formatted.fetch("message")
      assert_equal({ "service" => "core" }, formatted.fetch("labels"))
      refute formatted.key?("carry")
      refute formatted.key?("logger")
      refute formatted.key?("context")
      refute formatted.key?("payload")
      refute formatted.key?("error")
    end

    def test_default_formatter_compacts_execution_lineage
      record = build_record(
        { message: "hello" },
        context: {},
        scope: Julewire::Core::Execution::ScopeSnapshot.new(
          execution: {
            type: "request",
            id: "request-1",
            depth: 1,
            root: { type: "request", id: "request-1" },
            job_id: "job-1"
          }
        )
      )

      execution = formatted_record(record).fetch("execution")

      assert_equal({ "type" => "request", "id" => "request-1", "job_id" => "job-1" }, execution)
    end

    def test_default_formatter_omits_execution_when_only_internal_fields_remain
      record = build_record(
        { message: "hello" },
        context: {},
        scope: Julewire::Core::Execution::ScopeSnapshot.new(
          execution: {
            depth: 1,
            root: { type: "request", id: "request-1" }
          }
        )
      )

      formatted = formatted_record(record)

      refute formatted.key?("execution")
    end

    def test_default_formatter_preserves_empty_strings
      record = build_record(
        { message: "", event: "empty.message", source: "" },
        context: {},
        scope: nil
      )

      formatted = formatted_record(record)

      assert_equal "", formatted.fetch("message")
      assert_equal "", formatted.fetch("source")
    end

    private

    def formatted_record(record)
      JSON.parse(Julewire::Core::Serialization::JsonEncoder.new.call(Julewire::Core::Records::Formatter.new.call(record)))
    end
  end
end
