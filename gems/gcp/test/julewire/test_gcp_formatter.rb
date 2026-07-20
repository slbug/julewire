# frozen_string_literal: true

require "test_helper"
require "support/gcp_test_case"

module Julewire
  class GcpTest < GcpTestCase
    cover Julewire::GCP::Formatter
    cover "Julewire::GCP::Formatter#append_log_field"
    cover "Julewire::GCP::Formatter#initialize"
    cover "Julewire::GCP::Formatter#julewire_payload"
    cover "Julewire::GCP::Formatter#operation"
    cover "Julewire::GCP::Formatter#operation_options"
    cover "Julewire::GCP::Formatter#trace"
    cover "Julewire::GCP::Formatter#true_value?"
    cover Julewire::GCP::ExecutionPayload
    cover Julewire::GCP::HttpRequestFields
    def test_formats_basic_cloud_logging_fields
      formatted = formatted_order_record

      assert_equal(
        { "severity" => "WARNING", "message" => "created", "event" => "orders.created" },
        {
          "severity" => formatted.fetch("severity"),
          "message" => formatted.fetch("message"),
          "event" => formatted.fetch("julewire").fetch("event")
        }
      )
    end

    def test_omits_empty_optional_log_fields
      formatted = raw_empty_optional_record

      assert_equal(
        optional_log_field_names.to_h { [it, false] },
        field_presence(formatted, optional_log_field_names)
      )
    end

    def test_omits_empty_optional_julewire_fields
      formatted = raw_empty_optional_record

      assert_equal(
        {
          context: false,
          error: false,
          execution: false,
          logger: false,
          metrics: false,
          source: false
        },
        %i[context error execution logger metrics source].to_h { [it, formatted.fetch("julewire").key?(it)] }
      )
    end

    def test_formats_trace_labels_without_http_request_on_point_records
      formatted = formatted_order_record

      assert_equal expected_trace_fields.merge(julewire_execution: false), trace_fields(formatted)
      assert_false formatted.key?("httpRequest")
    end

    def test_omits_internal_and_empty_julewire_fields
      formatted = formatted_order_record

      assert_false formatted.fetch("julewire").key?("carry")
    end

    def test_julewire_payload_preserves_logger
      formatted = GCP::Formatter.new.call(normalized_record(logger: "Rails"))

      assert_equal "Rails", formatted.fetch("julewire").fetch(:logger)
    end

    def test_adds_operation_from_execution
      formatted = formatted_record(request_summary_record)

      assert_equal(
        { "id" => "request-1", "producer" => "rails", "last" => true },
        formatted.fetch("logging.googleapis.com/operation")
      )
      assert_equal(
        { "type" => "request" },
        formatted.fetch("julewire").fetch("execution")
      )
      assert_equal expected_request_summary_http_fields, formatted.fetch("httpRequest")
    end

    def test_keeps_custom_execution_fields
      record = normalized_record(
        execution: { type: "job", id: "job-1", correlation_id: "corr-1" }
      )

      formatted = formatted_record(record)

      assert_equal(
        { "type" => "job", "correlation_id" => "corr-1" },
        formatted.fetch("julewire").fetch("execution")
      )
      assert_equal "job-1", formatted.fetch("logging.googleapis.com/operation").fetch("id")
    end

    def test_keeps_execution_id_when_manual_operation_id_is_used
      record = normalized_record(
        execution: { type: "job", id: "job-1", correlation_id: "corr-1" },
        payload: GCP.operation(id: "manual-op-1")
      )

      formatted = formatted_record(record)

      assert_equal "manual-op-1", formatted.fetch("logging.googleapis.com/operation").fetch("id")
      assert_equal(
        { "type" => "job", "id" => "job-1", "correlation_id" => "corr-1" },
        formatted.fetch("julewire").fetch("execution")
      )
    end

    def test_omits_execution_id_when_manual_operation_id_is_false
      record = normalized_record(
        execution: { type: "job", id: "job-1", correlation_id: "corr-1" },
        payload: GCP.operation(id: false)
      )

      formatted = formatted_record(record)

      assert_equal "job-1", formatted.fetch("logging.googleapis.com/operation").fetch("id")
      assert_equal(
        { "type" => "job", "correlation_id" => "corr-1" },
        formatted.fetch("julewire").fetch("execution")
      )
    end

    def test_omits_internal_execution_relationship_fields
      record = normalized_record(
        execution: {
          type: "job",
          id: "job-1",
          depth: 3,
          root: { type: "request", id: "request-1" },
          parent: { type: "job", id: "parent-job-1" },
          correlation_id: "corr-1"
        }
      )

      formatted = formatted_record(record)

      assert_equal(
        { "type" => "job", "correlation_id" => "corr-1" },
        formatted.fetch("julewire").fetch("execution")
      )
    end

    def test_request_summary_attributes_omit_values_promoted_to_gcp_fields
      record = normalized_record(
        kind: :summary,
        source: "rails",
        execution: { type: "request", id: "request-1" },
        context: { request_id: "request-1" },
        neutral: Core::Fields::FieldSet.merge(
          request_summary_neutral,
          Core::Fields::AttributeKeys.fields("job.name": "ImportJob")
        ),
        attributes: {
          rails: {
            action_runtime_ms: 7.5,
            filtered_path: "/hello",
            error_class: "RuntimeError"
          }
        },
        metrics: { duration_ms: 123.4 },
        error: { class: "RuntimeError", message: "boom" }
      )

      formatted = formatted_record(record)

      assert_equal(
        { "rails" => { "action_runtime_ms" => 7.5, "filtered_path" => "/hello", "error_class" => "RuntimeError" } },
        formatted.fetch("attributes")
      )
      assert_false formatted.key?("payload")
    end

    def test_operation_uses_lineage_root_when_public_execution_has_no_id
      base = normalized_record(
        event: "job.completed",
        source: "worker",
        execution: {
          type: "job",
          root: { type: "request", id: "request-1" },
          depth: 2
        }
      )
      data = base.to_h
      data[:execution] = data.fetch(:execution).except(:id, :root)
      record = Core::Records::Record.from_normalized_hash(data, lineage: base.lineage)

      formatted = formatted_record(record)

      assert_equal(
        { "id" => "request-1", "producer" => "worker" },
        formatted.fetch("logging.googleapis.com/operation")
      )
      assert_false record.fetch(:execution).key?(:root)
    end

    def test_operation_uses_public_execution_id_before_empty_lineage
      record = normalized_record(execution: { type: "job", id: 123 })
      data = record.to_h
      data[:execution] = data.fetch(:execution).except(:root)
      record = Core::Records::Record.from_normalized_hash(data, lineage: Core::Execution::Lineage.new)

      formatted = formatted_record(record)

      assert_equal({ "id" => "123" }, formatted.fetch("logging.googleapis.com/operation"))
    end

    def test_operation_uses_logger_as_last_producer_fallback
      record = normalized_record(
        source: nil,
        logger: "Rails",
        execution: { type: "request", id: "request-1" }
      )

      formatted = formatted_record(record)

      assert_equal(
        { "id" => "request-1", "producer" => "Rails" },
        formatted.fetch("logging.googleapis.com/operation")
      )
    end

    def test_operation_uses_formatter_producer_before_record_source
      record = normalized_record(
        source: "worker",
        execution: { type: "job", id: "job-1" }
      )

      formatted = formatted_record(record, formatter: GCP::Formatter.new(operation_producer: "service"))

      assert_equal(
        { "id" => "job-1", "producer" => "service" },
        formatted.fetch("logging.googleapis.com/operation")
      )
    end

    def test_manual_operation_false_strings_do_not_mark_boundaries
      assert_equal(
        { "id" => "job-1" },
        formatted_operation_for_manual_flags(first: "false", last: "false")
      )
    end

    def test_manual_operation_truthy_strings_mark_boundaries
      assert_equal(
        { "id" => "job-1", "first" => true, "last" => true },
        formatted_operation_for_manual_flags(first: "YES", last: "TRUE")
      )
    end

    def formatted_operation_for_manual_flags(first:, last:)
      record = normalized_record(
        execution: { type: "job", id: "job-1" },
        payload: GCP.operation(first:, last:)
      )

      formatted = formatted_record(record)

      formatted.fetch("logging.googleapis.com/operation")
    end

    def test_non_hash_manual_operation_payload_falls_back_to_execution
      record = normalized_record(
        execution: { type: "job", id: "job-1" },
        payload: { gcp: { operation: "not-options" } }
      )

      formatted = formatted_record(record)

      assert_equal({ "id" => "job-1" }, formatted.fetch("logging.googleapis.com/operation"))
    end

    def test_does_not_map_non_request_duration_to_http_latency
      record = normalized_record(
        event: "active_record.sql",
        payload: { duration_ms: 12.5, status: 200, path: "/orders" },
        metrics: { duration_ms: 12.5 }
      )

      formatted = formatted_record(record)

      assert_false formatted.key?("httpRequest")
    end

    def test_omits_empty_payload_and_julewire_fields
      record = normalized_record(message: nil, payload: {}, context: {})

      formatted = formatted_record(record)

      assert_false formatted.key?("message")
      assert_false formatted.key?("payload")
      assert_false formatted.fetch("julewire").key?("context")
    end

    def test_leaves_bare_trace_id_unexpanded_without_project_id
      record = normalized_record(carry: trace_carry)

      formatted = formatted_record(record)

      assert_equal "06796866738c859f2f19b7cfb3214824", formatted.fetch("logging.googleapis.com/trace")
    end

    def test_keeps_remaining_gcp_payload_control_data
      record = normalized_record(
        payload: {
          gcp: {
            operation: { id: "op-1" },
            source_location: { file: "worker.rb" },
            extra: "kept"
          }
        }
      )

      formatted = formatted_record(record)

      assert_equal({ "gcp" => { "extra" => "kept" } }, formatted.fetch("payload"))
    end

    def test_removes_hash_subclass_gcp_payload_control_data
      control = Class.new(Hash).new
      operation = Class.new(Hash).new
      operation[:id] = "op-1"
      control[:operation] = operation
      record = owned_record(payload: { gcp: control })

      formatted = formatted_record(record)

      assert_equal({ "id" => "op-1" }, formatted.fetch("logging.googleapis.com/operation"))
      assert_false formatted.key?("payload")
    end

    def test_omits_empty_gcp_payload_control_container
      record = normalized_record(payload: { gcp: {} })

      formatted = GCP::Formatter.new.call(record)

      assert_false formatted.key?("payload")
    end

    def test_keeps_non_hash_gcp_payload_data
      record = normalized_record(payload: { gcp: "kept" })

      formatted = formatted_record(record)

      assert_equal({ "gcp" => "kept" }, formatted.fetch("payload"))
    end

    def test_omits_http_request_when_request_summary_has_no_http_fields
      record = normalized_record(kind: :summary, event: "request.completed")

      formatted = formatted_record(record)

      assert_false formatted.key?("httpRequest")
    end

    def test_omits_invalid_http_latency
      record = normalized_record(
        kind: :summary,
        event: "request.completed",
        neutral: Core::Fields::AttributeKeys.fields("http.request.method": "GET"),
        metrics: { duration_ms: Object.new }
      )

      formatted = formatted_record(record)

      assert_equal({ "requestMethod" => "GET" }, formatted.fetch("httpRequest"))
    end

    def test_omits_http_latency_when_duration_metric_is_missing
      record = normalized_record(
        kind: :summary,
        event: "request.completed",
        neutral: Core::Fields::AttributeKeys.fields("http.request.method": "GET")
      )

      formatted = formatted_record(record)
      raw = GCP::Formatter.new.call(record)

      assert_equal({ "requestMethod" => "GET" }, formatted.fetch("httpRequest"))
      assert_equal({ "requestMethod" => "GET" }, raw.fetch("httpRequest"))
    end

    def test_maps_http_fields_by_attribute_presence
      record = normalized_record(
        kind: :point,
        event: "http.client",
        neutral: request_summary_neutral,
        attributes: request_summary_attributes,
        metrics: { duration_ms: 8.5 }
      )

      formatted = formatted_record(record)

      assert_equal expected_request_summary_http_fields.merge("latency" => "0.0085s"), formatted.fetch("httpRequest")
      assert_equal({ "rails" => { "filtered_path" => "/hello" } }, formatted.fetch("attributes"))
    end

    def test_formats_whole_second_http_latency_without_decimal_point
      record = normalized_record(
        kind: :summary,
        event: "request.completed",
        neutral: Core::Fields::AttributeKeys.fields("http.request.method": "GET"),
        metrics: { duration_ms: 1000 }
      )

      formatted = GCP::Formatter.new.call(record)

      assert_equal "1s", formatted.fetch("httpRequest").fetch("latency")
    end

    def test_maps_http_request_url_from_path_when_full_url_is_missing
      record = normalized_record(
        kind: :point,
        event: "http.client",
        neutral: Core::Fields::AttributeKeys.fields(
          "http.request.method": "GET",
          "url.path": "/fallback"
        )
      )

      formatted = formatted_record(record)

      assert_equal(
        { "requestMethod" => "GET", "requestUrl" => "/fallback" },
        formatted.fetch("httpRequest")
      )
    end

    private

    def request_summary_record
      normalized_record(
        kind: :summary,
        source: "rails",
        execution: { type: "request", id: "request-1" },
        context: { request_id: "request-1" },
        neutral: request_summary_neutral,
        attributes: request_summary_attributes,
        metrics: { duration_ms: 123.4 },
        payload: {}
      )
    end

    def formatted_order_record
      record = normalized_record(
        severity: :warn,
        message: "created",
        event: "orders.created",
        source: "rails",
        logger: "Rails",
        labels: { tenant: "acme", shard: 2 },
        context: order_context,
        carry: order_carry,
        payload: order_payload
      )

      formatted_record(record, formatter: GCP::Formatter.new(project_id: "project-1"))
    end

    def raw_empty_optional_record
      GCP::Formatter.new(service_context: []).call(
        normalized_record(
          attributes: {},
          context: {},
          execution: {},
          labels: {},
          metrics: {},
          payload: {}
        )
      )
    end

    def optional_log_field_names
      %w[
        attributes
        httpRequest
        logging.googleapis.com/labels
        logging.googleapis.com/operation
        logging.googleapis.com/sourceLocation
        logging.googleapis.com/spanId
        logging.googleapis.com/trace
        logging.googleapis.com/trace_sampled
        payload
        serviceContext
        stack_trace
      ]
    end

    def field_presence(hash, keys)
      keys.to_h { [it, hash.key?(it)] }
    end

    def order_context
      {
        http_method: "POST",
        path: "/orders",
        remote_ip: "127.0.0.1"
      }
    end

    def order_payload
      {
        id: 123,
        status: 201,
        user_agent: "curl",
        response_bytes: 456
      }
    end

    def order_carry
      {
        http: {
          request_headers: {
            tracestate: "vendor=value",
            "x-cloud-trace-context" => "ignored",
            "traceparent" => "00-06796866738c859f2f19b7cfb3214824-000000000000004a-00"
          }
        }
      }
    end

    def expected_trace_fields
      {
        trace_project: "project-1",
        span_id: "000000000000004a",
        trace_sampled: false,
        labels: { "tenant" => "acme", "shard" => "2" },
        payload_id: 123
      }
    end

    def trace_fields(formatted)
      {
        trace_project: formatted.fetch("logging.googleapis.com/trace").split("/").fetch(1),
        span_id: formatted.fetch("logging.googleapis.com/spanId"),
        trace_sampled: formatted.fetch("logging.googleapis.com/trace_sampled"),
        labels: formatted.fetch("logging.googleapis.com/labels"),
        payload_id: formatted.fetch("payload").fetch("id"),
        julewire_execution: formatted.fetch("julewire").key?("execution")
      }
    end

    def expected_request_summary_http_fields
      {
        "requestMethod" => "GET",
        "requestUrl" => "http://example.com/hello",
        "status" => 200,
        "userAgent" => "curl",
        "remoteIp" => "127.0.0.1",
        "responseSize" => "456",
        "latency" => "0.1234s"
      }
    end
  end
end
