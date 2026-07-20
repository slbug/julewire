# frozen_string_literal: true

require "test_helper"
require "support/gcp_test_case"

module Julewire
  class GcpNonRequestSummaryTest < GcpTestCase
    cover "Julewire::GCP::Formatter#call"
    cover Julewire::GCP::HttpRequestFields
    def test_formats_job_summary_without_http_request
      record = normalized_record(
        kind: :summary,
        event: "job.completed",
        source: "active_job",
        execution: { type: "job", id: "job-1" },
        carry: trace_carry,
        metrics: { duration_ms: 25.5 },
        payload: { status: "ok" }
      )

      formatted = formatted_record(record, formatter: GCP::Formatter.new(project_id: "project-1"))

      assert_false formatted.key?("httpRequest")
      assert_equal(
        { "id" => "job-1", "producer" => "active_job", "last" => true },
        formatted.fetch("logging.googleapis.com/operation")
      )
      assert_equal "projects/project-1/traces/06796866738c859f2f19b7cfb3214824",
                   formatted.fetch("logging.googleapis.com/trace")
    end

    def test_formats_non_request_summary_without_http_request
      record = normalized_record(
        kind: :summary,
        event: "batch.completed",
        source: "worker",
        execution: { type: "batch", id: "batch-1" },
        carry: trace_carry,
        metrics: { duration_ms: 31.25 },
        payload: { items_count: 3, status: "ok" }
      )

      formatted = formatted_record(record, formatter: GCP::Formatter.new(project_id: "project-1"))

      assert_false formatted.key?("httpRequest")
      assert_equal(
        { "id" => "batch-1", "producer" => "worker", "last" => true },
        formatted.fetch("logging.googleapis.com/operation")
      )
      assert_equal "000000000000004a", formatted.fetch("logging.googleapis.com/spanId")
    end
  end

  module GcpTraceHelpers
    class IndexedOnlyHeaders
      def initialize(values)
        @values = values
      end

      def [](key)
        @values[key]
      end
    end

    class EmptyIterableHeaders
      def [](*) = nil

      def each = "06796866738c859f2f19b7cfb3214824/74;o=1"
    end
    private_constant :IndexedOnlyHeaders
    private_constant :EmptyIterableHeaders

    private

    def configured_trace_context
      {
        cloud: {
          trace_id: "06796866738c859f2f19b7cfb3214824",
          span_id: "000000000000004a",
          sampled: true
        }
      }
    end

    def formatted_context_trace_record(record)
      formatted_record(
        record,
        formatter: GCP::Formatter.new(
          project_id: "project-1",
          trace_id_path: %i[context cloud trace_id],
          span_id_path: %i[context cloud span_id],
          trace_sampled_path: %i[context cloud sampled]
        )
      )
    end

    def formatted_trace_header_record(name, value)
      formatted_record(
        normalized_record(payload: { request_headers: { name => value } }),
        formatter: GCP::Formatter.new(project_id: "project-1")
      )
    end

    def assert_trace_context(formatted, span: true, sampled: true)
      assert_equal "projects/project-1/traces/06796866738c859f2f19b7cfb3214824",
                   formatted.fetch("logging.googleapis.com/trace")
      assert_equal "000000000000004a", formatted.fetch("logging.googleapis.com/spanId") if span
      if sampled
        assert_true formatted.fetch("logging.googleapis.com/trace_sampled")
      else
        assert_false formatted.fetch("logging.googleapis.com/trace_sampled")
      end
    end

    def formatted_execution_trace_record
      formatted_record(
        normalized_record(execution: execution_trace_fields),
        formatter: GCP::Formatter.new(
          project_id: "project-1",
          trace_id_path: %i[execution trace_id],
          span_id_path: %i[execution span_id],
          trace_sampled_path: %i[execution sampled]
        )
      )
    end

    def execution_trace_fields
      {
        type: "job",
        id: "job-1",
        trace_id: "06796866738c859f2f19b7cfb3214824",
        span_id: "000000000000004a",
        sampled: true,
        correlation_id: "corr-1"
      }
    end

    def execution_trace_summary(formatted)
      {
        trace: formatted.fetch("logging.googleapis.com/trace"),
        span: formatted.fetch("logging.googleapis.com/spanId"),
        sampled: formatted.fetch("logging.googleapis.com/trace_sampled"),
        execution: formatted.fetch("julewire").fetch("execution")
      }
    end

    def expected_execution_trace_summary
      {
        trace: "projects/project-1/traces/06796866738c859f2f19b7cfb3214824",
        span: "000000000000004a",
        sampled: true,
        execution: { "type" => "job", "correlation_id" => "corr-1" }
      }
    end

    def cloud_trace_payload
      {
        request_headers: {
          "x-cloud-trace-context" => "06796866738c859f2f19b7cfb3214824/74;o=1"
        }
      }
    end
  end
  private_constant :GcpTraceHelpers

  class GcpTracePathTest < GcpTestCase
    cover "Julewire::GCP::Formatter#append_special_fields"
    cover "Julewire::GCP::Formatter#initialize"
    cover "Julewire::GCP::Formatter#julewire_payload"
    cover "Julewire::GCP::Formatter#trace"
    cover "Julewire::GCP::Formatter#trace_value"
    cover Julewire::GCP::FormatterOptions
    cover Julewire::GCP::ExecutionPayload
    include GcpTraceHelpers

    def test_can_map_trace_fields_from_configured_paths
      record = normalized_record(context: configured_trace_context)

      formatted = formatted_context_trace_record(record)

      assert_trace_context(formatted)
    end

    def test_preserves_configured_trace_path_values
      record = normalized_record(
        context: {
          cloud: configured_trace_context.fetch(:cloud).merge(
            trace_id: "projects/upstream-project/traces/06796866738c859f2f19b7cfb3214824",
            sampled: "yes"
          )
        }
      )

      formatted = formatted_context_trace_record(record)

      assert_equal "projects/upstream-project/traces/06796866738c859f2f19b7cfb3214824",
                   formatted.fetch("logging.googleapis.com/trace")
      assert_equal "yes", formatted.fetch("logging.googleapis.com/trace_sampled")
    end

    def test_omits_execution_trace_fields_promoted_to_gcp_trace
      formatted = formatted_execution_trace_record

      assert_equal expected_execution_trace_summary, execution_trace_summary(formatted)
    end

    def test_accepts_string_execution_trace_path_keys
      formatted = formatted_record(
        normalized_record(execution: execution_trace_fields),
        formatter: GCP::Formatter.new(
          project_id: "project-1",
          trace_id_path: %w[execution trace_id],
          span_id_path: %w[execution span_id],
          trace_sampled_path: %w[execution sampled]
        )
      )

      assert_equal expected_execution_trace_summary, execution_trace_summary(formatted)
    end

    def test_keeps_execution_fields_for_malformed_trace_paths
      formatted = formatted_record(
        normalized_record(execution: execution_trace_fields),
        formatter: GCP::Formatter.new(
          project_id: "project-1",
          trace_id_path: %i[execution],
          span_id_path: %i[context span_id],
          trace_sampled_path: :sampled
        )
      )

      assert_false formatted.key?("logging.googleapis.com/trace")
      assert_equal expected_unpromoted_execution_trace_fields, formatted.fetch("julewire").fetch("execution")
    end

    def test_keeps_nested_execution_trace_container
      formatted = formatted_record(
        normalized_record(
          execution: {
            type: "job",
            id: "job-1",
            cloud: {
              trace_id: "06796866738c859f2f19b7cfb3214824"
            }
          }
        ),
        formatter: GCP::Formatter.new(
          project_id: "project-1",
          trace_id_path: %i[execution cloud trace_id]
        )
      )

      assert_equal(
        {
          "type" => "job",
          "cloud" => {
            "trace_id" => "06796866738c859f2f19b7cfb3214824"
          }
        },
        formatted.fetch("julewire").fetch("execution")
      )
    end

    def test_keeps_blank_execution_trace_fields_in_payload
      formatted = formatted_record(
        normalized_record(
          execution: {
            type: "job",
            id: "job-1",
            trace_id: "",
            correlation_id: "corr-1"
          }
        ),
        formatter: GCP::Formatter.new(
          project_id: "project-1",
          trace_id_path: %i[execution trace_id]
        )
      )

      assert_false formatted.key?("logging.googleapis.com/trace")
      assert_equal(
        { "type" => "job", "trace_id" => "", "correlation_id" => "corr-1" },
        formatted.fetch("julewire").fetch("execution")
      )
    end

    def test_accepts_string_subclass_execution_trace_path_keys
      string = Class.new(String)
      formatted = formatted_record(
        normalized_record(execution: execution_trace_fields),
        formatter: GCP::Formatter.new(
          project_id: "project-1",
          trace_id_path: [string.new("execution"), string.new("trace_id")],
          span_id_path: [string.new("execution"), string.new("span_id")],
          trace_sampled_path: [string.new("execution"), string.new("sampled")]
        )
      )

      assert_equal expected_execution_trace_summary, execution_trace_summary(formatted)
    end

    def test_keeps_execution_fields_for_nil_trace_path_segments
      formatted = formatted_record(
        normalized_record(execution: execution_trace_fields),
        formatter: GCP::Formatter.new(project_id: "project-1", trace_id_path: [nil, :trace_id])
      )

      assert_false formatted.key?("logging.googleapis.com/trace")
      assert_equal expected_unpromoted_execution_trace_fields, formatted.fetch("julewire").fetch("execution")
    end

    def test_keeps_execution_fields_for_false_trace_path_segments
      formatted = formatted_record(
        normalized_record(execution: execution_trace_fields),
        formatter: GCP::Formatter.new(project_id: "project-1", trace_id_path: [false, :trace_id])
      )

      assert_false formatted.key?("logging.googleapis.com/trace")
      assert_equal expected_unpromoted_execution_trace_fields, formatted.fetch("julewire").fetch("execution")
    end

    def test_formats_stringifiable_trace_id_from_configured_path
      trace_id = Object.new
      trace_id.define_singleton_method(:to_s) { "06796866738c859f2f19b7cfb3214824" }
      record = normalized_record(context: { trace_id: trace_id })

      formatted = GCP::Formatter.new(project_id: "project-1", trace_id_path: %i[context trace_id]).call(record)

      assert_equal "projects/project-1/traces/06796866738c859f2f19b7cfb3214824",
                   formatted.fetch("logging.googleapis.com/trace")
    end

    def expected_unpromoted_execution_trace_fields
      {
        "type" => "job",
        "trace_id" => "06796866738c859f2f19b7cfb3214824",
        "span_id" => "000000000000004a",
        "sampled" => true,
        "correlation_id" => "corr-1"
      }
    end
  end

  class GcpTraceHeaderTest < GcpTestCase
    cover "Julewire::GCP::Formatter#initialize"
    cover "Julewire::GCP::Formatter#trace"
    cover "Julewire::GCP::Formatter#trace_context"
    cover "Julewire::GCP::Formatter#trace_value"
    cover Julewire::GCP::FormatterOptions
    cover Julewire::GCP::TraceContext
    cover Julewire::GCP::TraceContext::Traceparent
    include GcpTraceHelpers

    def test_nil_trace_header_paths_disable_header_extraction
      record = normalized_record(payload: cloud_trace_payload)

      formatted = formatted_record(record, formatter: GCP::Formatter.new(trace_headers_paths: nil))

      assert_false formatted.key?("logging.googleapis.com/trace")
    end

    def test_trace_header_path_options_drop_too_short_paths
      assert_equal(
        [%i[payload request_headers]],
        GCP::FormatterOptions.trace_headers_paths([[], %i[payload request_headers]])
      )
    end

    def test_default_trace_header_paths_include_context_request_headers
      record = normalized_record(
        context: {
          request_headers: {
            "traceparent" => "00-06796866738c859f2f19b7cfb3214824-000000000000004a-01"
          }
        }
      )

      formatted = formatted_record(record, formatter: GCP::Formatter.new(project_id: "project-1"))

      assert_trace_context(formatted)
    end

    def test_trace_header_paths_keep_non_string_index_segments
      record = normalized_record(
        payload: {
          request_headers: [
            { "traceparent" => "00-06796866738c859f2f19b7cfb3214824-000000000000004a-01" }
          ]
        }
      )

      formatted = formatted_record(
        record,
        formatter: GCP::Formatter.new(project_id: "project-1", trace_headers_paths: [%i[payload request_headers] + [0]])
      )

      assert_trace_context(formatted)
    end

    def test_trace_header_paths_drop_too_short_paths
      record = normalized_record(payload: cloud_trace_payload)

      formatted = formatted_record(
        record,
        formatter: GCP::Formatter.new(project_id: "project-1", trace_headers_paths: [[]])
      )

      assert_false formatted.key?("logging.googleapis.com/trace")
    end

    def test_parses_x_cloud_trace_context_when_traceparent_is_missing
      record = normalized_record(payload: cloud_trace_payload)

      formatted = formatted_record(record, formatter: GCP::Formatter.new(project_id: "project-1"))

      assert_equal "projects/project-1/traces/06796866738c859f2f19b7cfb3214824",
                   formatted.fetch("logging.googleapis.com/trace")
      assert_equal "000000000000004a", formatted.fetch("logging.googleapis.com/spanId")
      assert_true formatted.fetch("logging.googleapis.com/trace_sampled")
    end

    def test_rejects_extra_traceparent_fields_for_version_zero
      record = normalized_record(
        payload: {
          request_headers: {
            "traceparent" => "00-06796866738c859f2f19b7cfb3214824-000000000000004a-01-extra"
          }
        }
      )

      formatted = formatted_record(record, formatter: GCP::Formatter.new(project_id: "project-1"))

      assert_false formatted.key?("logging.googleapis.com/trace")
      assert_false formatted.key?("logging.googleapis.com/spanId")
    end

    def test_allows_extra_traceparent_fields_for_future_versions
      formatted = formatted_trace_header_record(
        "traceparent",
        "01-06796866738c859f2f19b7cfb3214824-000000000000004a-01-extra"
      )

      assert_equal "projects/project-1/traces/06796866738c859f2f19b7cfb3214824",
                   formatted.fetch("logging.googleapis.com/trace")
      assert_equal "000000000000004a", formatted.fetch("logging.googleapis.com/spanId")
      assert_true formatted.fetch("logging.googleapis.com/trace_sampled")
    end

    def test_parses_padded_traceparent_header_values
      formatted = formatted_trace_header_record(
        "traceparent",
        "  00-06796866738c859f2f19b7cfb3214824-000000000000004a-01\n"
      )

      assert_trace_context(formatted, span: false)
    end

    def test_parses_uppercase_traceparent_header_values
      formatted = formatted_trace_header_record(
        "traceparent",
        "00-06796866738C859F2F19B7CFB3214824-000000000000004A-0A"
      )

      assert_trace_context(formatted, sampled: false)
    end

    def test_rejects_future_traceparent_extra_data_without_separator
      formatted = formatted_trace_header_record(
        "traceparent",
        "01-06796866738c859f2f19b7cfb3214824-000000000000004a-01extra"
      )

      assert_false formatted.key?("logging.googleapis.com/trace")
    end

    def test_rejects_uppercase_ff_traceparent_version
      assert_nil GCP::TraceContext.parse_traceparent(
        "FF-06796866738c859f2f19b7cfb3214824-000000000000004a-01"
      )
    end

    def test_traceparent_reads_flags_as_hex
      context = GCP::TraceContext.parse_traceparent(
        "00-06796866738c859f2f19b7cfb3214824-000000000000004a-10"
      )

      assert_false context.fetch(:trace_sampled)
    end

    def test_traceparent_accepts_nonzero_trace_id_nibbles_at_each_parity
      %w[
        10000000000000000000000000000000
        01000000000000000000000000000000
      ].each do |trace_id|
        assert_equal(
          trace_id,
          GCP::TraceContext.parse_traceparent("00-#{trace_id}-000000000000004a-01").fetch(:trace_id)
        )
      end
    end

    def test_rejects_x_cloud_trace_context_span_ids_larger_than_uint64
      formatted = formatted_trace_header_record(
        "x-cloud-trace-context",
        "06796866738c859f2f19b7cfb3214824/18446744073709551616;o=1"
      )

      assert_equal "projects/project-1/traces/06796866738c859f2f19b7cfb3214824",
                   formatted.fetch("logging.googleapis.com/trace")
      assert_false formatted.key?("logging.googleapis.com/spanId")
    end

    def test_rejects_invalid_traceparent_components
      invalid_headers = %w[
        ff-06796866738c859f2f19b7cfb3214824-000000000000004a-01
        x0-06796866738c859f2f19b7cfb3214824-000000000000004a-01
        00006796866738c859f2f19b7cfb3214824-000000000000004a-01
        00-06796866738c859f2f19b7cfb3214824x000000000000004a-01
        00-06796866738c859f2f19b7cfb3214824-000000000000004ax01
        00-xyz-000000000000004a-01
        00-06796866738c859f2f19b7cfb3214824-xyz-01
        00-06796866738c859f2f19b7cfb3214824-000000000000004a-zz
        00-00000000000000000000000000000000-000000000000004a-01
        00-06796866738c859f2f19b7cfb3214824-0000000000000000-01
      ]

      invalid_headers.each do |traceparent|
        record = normalized_record(payload: { request_headers: { traceparent: traceparent } })

        formatted = formatted_record(record, formatter: GCP::Formatter.new(project_id: "project-1"))

        assert_false formatted.key?("logging.googleapis.com/trace"), traceparent
      end
    end

    def test_rejects_invalid_x_cloud_trace_context
      invalid_headers = [
        "not-a-trace",
        "00000000000000000000000000000000/74;o=1",
        "06796866738c859f2f19b7cfb3214824/not-decimal;o=1"
      ]

      invalid_headers.each do |header|
        record = normalized_record(payload: { request_headers: { "x-cloud-trace-context" => header } })

        formatted = formatted_record(record, formatter: GCP::Formatter.new(project_id: "project-1"))

        assert_false formatted.key?("logging.googleapis.com/trace"), header
      end
    end

    def test_fetches_trace_headers_case_insensitively
      record = normalized_record(
        payload: {
          request_headers: {
            "TraceParent" => trace_carry.dig(:http, :request_headers, "traceparent")
          }
        }
      )

      formatted = formatted_record(record, formatter: GCP::Formatter.new(project_id: "project-1"))

      assert_equal "000000000000004a", formatted.fetch("logging.googleapis.com/spanId")
    end
  end

  class GcpTraceExtractionTest < GcpTestCase
    cover Julewire::GCP::TraceContext
    include GcpTraceHelpers

    def test_trace_context_extract_ignores_objects_without_header_lookup
      assert_empty GCP::TraceContext.extract(Object.new)
    end

    def test_trace_context_extract_accepts_indexed_headers_without_each
      headers = IndexedOnlyHeaders.new(
        traceparent: "00-06796866738c859f2f19b7cfb3214824-000000000000004a-01"
      )

      assert_equal(
        {
          trace_id: "06796866738c859f2f19b7cfb3214824",
          span_id: "000000000000004a",
          trace_sampled: true
        },
        GCP::TraceContext.extract(headers)
      )
    end

    def test_trace_context_extract_accepts_direct_string_traceparent_without_each
      assert_indexed_header_trace(
        "traceparent" => "00-06796866738c859f2f19b7cfb3214824-000000000000004a-01"
      )
    end

    def test_trace_context_extract_accepts_underscore_x_cloud_header_without_each
      assert_indexed_header_trace(
        "x_cloud_trace_context" => "06796866738c859f2f19b7cfb3214824/74;o=1"
      )
    end

    def test_trace_context_extract_accepts_dashed_x_cloud_header_without_each
      assert_indexed_header_trace(
        "x-cloud-trace-context" => "06796866738c859f2f19b7cfb3214824/74;o=1"
      )
    end

    def assert_indexed_header_trace(headers)
      assert_equal(
        {
          trace_id: "06796866738c859f2f19b7cfb3214824",
          span_id: "000000000000004a",
          trace_sampled: true
        },
        GCP::TraceContext.extract(IndexedOnlyHeaders.new(headers))
      )
    end

    def test_trace_context_extract_does_not_mutate_iterated_header_names
      name = "X_CLOUD_TRACE_CONTEXT"

      assert_equal(
        {
          trace_id: "06796866738c859f2f19b7cfb3214824",
          span_id: "000000000000004a",
          trace_sampled: true
        },
        GCP::TraceContext.extract(name => "06796866738c859f2f19b7cfb3214824/74;o=1")
      )

      assert_equal "X_CLOUD_TRACE_CONTEXT", name
    end

    def test_trace_context_extract_skips_unrelated_iterated_headers
      headers = {
        "x-julewire-test" => "00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-000000000000004a-01",
        "TraceParent" => "00-06796866738c859f2f19b7cfb3214824-000000000000004a-01"
      }

      assert_equal(
        {
          trace_id: "06796866738c859f2f19b7cfb3214824",
          span_id: "000000000000004a",
          trace_sampled: true
        },
        GCP::TraceContext.extract(headers)
      )
    end

    def test_trace_context_extract_ignores_unrelated_iterated_headers
      assert_empty GCP::TraceContext.extract("x-julewire-test" => "not a trace")
    end

    def test_trace_context_extract_ignores_iterable_return_value
      assert_empty GCP::TraceContext.extract(EmptyIterableHeaders.new)
    end
  end

  class GcpXCloudTraceContextTest < GcpTestCase
    cover Julewire::GCP::TraceContext
    def test_x_cloud_trace_context_trims_surrounding_whitespace
      assert_equal(
        {
          trace_id: "06796866738c859f2f19b7cfb3214824",
          span_id: "000000000000004a",
          trace_sampled: true
        },
        GCP::TraceContext.parse_x_cloud_trace_context(
          "  06796866738c859f2f19b7cfb3214824/74;o=1\n"
        )
      )
    end

    def test_x_cloud_trace_context_accepts_trace_id_without_span_or_options
      assert_equal(
        {
          trace_id: "06796866738c859f2f19b7cfb3214824"
        },
        GCP::TraceContext.parse_x_cloud_trace_context(
          "06796866738c859f2f19b7cfb3214824"
        )
      )
    end

    def test_x_cloud_trace_context_accepts_trace_id_with_options_without_span
      assert_equal(
        {
          trace_id: "06796866738c859f2f19b7cfb3214824",
          trace_sampled: true
        },
        GCP::TraceContext.parse_x_cloud_trace_context(
          "06796866738c859f2f19b7cfb3214824;o=1"
        )
      )
    end

    def test_x_cloud_trace_context_omits_sampled_when_options_are_absent
      assert_equal(
        {
          trace_id: "06796866738c859f2f19b7cfb3214824",
          span_id: "000000000000004a"
        },
        GCP::TraceContext.parse_x_cloud_trace_context(
          "06796866738c859f2f19b7cfb3214824/74"
        )
      )
    end

    def test_x_cloud_trace_context_parses_padded_decimal_span_as_decimal
      assert_equal(
        {
          trace_id: "06796866738c859f2f19b7cfb3214824",
          span_id: "000000000000004a",
          trace_sampled: true
        },
        GCP::TraceContext.parse_x_cloud_trace_context(
          "06796866738c859f2f19b7cfb3214824/074;o=1"
        )
      )
    end

    def test_x_cloud_trace_context_downcases_trace_id
      assert_equal(
        {
          trace_id: "06796866738c859f2f19b7cfb3214824",
          span_id: "000000000000004a",
          trace_sampled: true
        },
        GCP::TraceContext.parse_x_cloud_trace_context(
          "06796866738C859F2F19B7CFB3214824/74;o=1"
        )
      )
    end

    def test_x_cloud_trace_context_reads_sampled_flag_from_low_bit
      assert_false GCP::TraceContext.parse_x_cloud_trace_context(
        "06796866738c859f2f19b7cfb3214824/74;o=2"
      ).fetch(:trace_sampled)
      assert_true GCP::TraceContext.parse_x_cloud_trace_context(
        "06796866738c859f2f19b7cfb3214824/74;o=3"
      ).fetch(:trace_sampled)
      assert_false GCP::TraceContext.parse_x_cloud_trace_context(
        "06796866738c859f2f19b7cfb3214824/74;o=10"
      ).fetch(:trace_sampled)
    end

    def test_x_cloud_trace_context_parses_sampled_option_as_decimal
      assert_true GCP::TraceContext.parse_x_cloud_trace_context(
        "06796866738c859f2f19b7cfb3214824/74;o=09"
      ).fetch(:trace_sampled)
    end

    def test_x_cloud_trace_context_omits_zero_span
      assert_equal(
        {
          trace_id: "06796866738c859f2f19b7cfb3214824",
          trace_sampled: true
        },
        GCP::TraceContext.parse_x_cloud_trace_context(
          "06796866738c859f2f19b7cfb3214824/0;o=1"
        )
      )
    end

    def test_x_cloud_trace_context_omits_span_larger_than_uint64
      assert_equal(
        {
          trace_id: "06796866738c859f2f19b7cfb3214824",
          trace_sampled: true
        },
        GCP::TraceContext.parse_x_cloud_trace_context(
          "06796866738c859f2f19b7cfb3214824/18446744073709551616;o=1"
        )
      )
    end
  end
end
