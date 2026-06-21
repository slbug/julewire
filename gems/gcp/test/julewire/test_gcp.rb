# frozen_string_literal: true

require "test_helper"
require "support/gcp_test_case"

module Julewire
  class GcpContractTest < GcpTestCase
    cover Julewire::GCP::Destination
    cover Julewire::GCP::ExecutionPayload
    cover Julewire::GCP::Formatter
    cover Julewire::GCP::HttpRequestFields
    cover Julewire::GCP::LabelFormatter

    def test_that_it_has_a_version_number
      refute_nil GCP::VERSION
    end

    def test_formatter_satisfies_julewire_formatter_contract
      formatted = assert_julewire_formatter_contract(GCP::Formatter.new)
      encoded = JSON.parse(Core::Serialization::JsonEncoder.new.call(formatted))

      assert_equal "test.event", encoded.fetch("julewire").fetch("event")
    end

    def test_gcp_uses_shared_julewire_validation_spi_contract
      assert_julewire_validation_spi_contract
    end

    def test_formatter_matches_request_summary_golden_fixture
      record = normalized_record(
        timestamp: Time.utc(2026, 5, 28, 12, 0, 0),
        kind: :summary,
        event: "request.completed",
        source: "rails",
        execution: { type: "request", id: "request-1" },
        context: { request_id: "request-1" },
        neutral: request_summary_neutral,
        attributes: request_summary_attributes,
        metrics: { duration_ms: 123.4 },
        payload: {}
      )

      assert_equal(
        gcp_fixture("request_summary"),
        formatted_record(record, formatter: GCP::Formatter.new(project_id: "project-1"))
      )
    end

    def test_formatter_satisfies_julewire_runtime_integration_contract
      output = StringIO.new

      point, summary, health = assert_julewire_runtime_integration_contract(
        configure: lambda do |config|
          config.destinations.add(
            GCP::Destination.new(
              formatter: GCP::Formatter.new(project_id: "project-1"),
              output: output
            )
          )
        end,
        records: -> { output.string.lines.map { JSON.parse(it) } },
        event_path: %w[julewire event],
        context_path: %w[julewire context],
        summary_payload_path: %w[payload],
        destination_name: :gcp
      )

      assert_runtime_contract_output(point, summary, health)
    end

    private

    def assert_runtime_contract_output(point, summary, health)
      assert_equal(expected_runtime_contract_output, runtime_contract_output(point, summary, health))
    end

    def expected_runtime_contract_output
      {
        trace: "projects/project-1/traces/06796866738c859f2f19b7cfb3214824",
        span: "000000000000004a",
        sampled: true,
        configured: true,
        summary_kind: "summary"
      }
    end

    def runtime_contract_output(point, summary, health)
      {
        trace: point.fetch("logging.googleapis.com/trace"),
        span: point.fetch("logging.googleapis.com/spanId"),
        sampled: point.fetch("logging.googleapis.com/trace_sampled"),
        configured: health.dig(:pipeline, :configured),
        summary_kind: summary.dig("julewire", "kind")
      }
    end
  end

  class GcpOptionsTest < GcpTestCase
    class RaisingOutput
      def initialize(error)
        @error = error
      end

      def write(_value) = raise @error
    end

    def test_exposes_carry_request_headers_for_rails_capture
      assert_equal %w[traceparent tracestate x-cloud-trace-context], GCP::CARRY_REQUEST_HEADERS
    end

    def test_destination_uses_recommended_record_size
      output = StringIO.new

      Julewire.configure do |config|
        config.destinations.add(GCP::Destination.new(output: output))
      end
      Julewire.emit(message: "fits")

      assert_match "fits", output.string
      assert_equal :ok, Julewire.health.dig(:pipeline, :destinations, :gcp, :status)
    end

    def test_destination_satisfies_destination_chaos_contract
      Julewire::Testing::Chaos.assert_destination_chaos_contract(
        self,
        record: normalized_record(message: "chaos"),
        formatter: ->(error) { formatter_chaos_destination(error) },
        encoder: ->(error) { encoder_chaos_destination(error) },
        output: ->(error) { GCP::Destination.new(output: RaisingOutput.new(error)) },
        callbacks: ->(error) { callback_chaos_destination(error) }
      )
    end

    def test_destination_keeps_record_size_configurable
      output = StringIO.new

      Julewire.configure do |config|
        config.destinations.add(GCP::Destination.new(output: output, max_record_bytes: 16))
      end
      Julewire.emit(message: "too large")

      assert_empty output.string
      assert_equal 1, Julewire.health.dig(:pipeline, :destinations, :gcp, :counts, :record_too_large)
    end

    def formatter_chaos_destination(error)
      GCP::Destination.new(
        output: StringIO.new,
        formatter: Julewire::Testing::Chaos.raiser(error)
      )
    end

    def encoder_chaos_destination(error)
      GCP::Destination.new(
        output: StringIO.new,
        encoder: Julewire::Testing::Chaos.raiser(error)
      )
    end

    def callback_chaos_destination(error)
      trigger = RuntimeError.new("formatter trigger")
      GCP::Destination.new(
        output: StringIO.new,
        formatter: Julewire::Testing::Chaos.raiser(trigger),
        on_drop: Julewire::Testing::Chaos.raiser(error),
        on_failure: Julewire::Testing::Chaos.raiser(error)
      )
    end

    def test_formatter_validates_label_limits
      assert_raises(ArgumentError) { GCP::Formatter.new(max_labels: 0) }
      assert_raises(ArgumentError) { GCP::Formatter.new(max_label_key_bytes: 0) }
      assert_raises(ArgumentError) { GCP::Formatter.new(max_label_value_bytes: 0) }
    end

    def test_formatter_snapshots_service_context
      service_context = { service: "api", version: "1" }
      formatter = GCP::Formatter.new(service_context: service_context)
      service_context[:version] = "2"

      formatted = formatted_record(formatter: formatter)

      assert_equal({ "service" => "api", "version" => "1" }, formatted.fetch("serviceContext"))
    end

    def test_builds_manual_operation_marker_payload
      assert_equal(
        { gcp: { operation: { id: "script-1", producer: "script", first: true, last: true } } },
        GCP.operation(id: "script-1", producer: "script", first: true, last: true)
      )
    end

    def test_builds_manual_source_location_payload
      assert_equal(
        { gcp: { source_location: { file: "app/jobs/import_job.rb", line: 42, function: "ImportJob#perform" } } },
        GCP.source_location(file: "app/jobs/import_job.rb", line: 42, function: "ImportJob#perform")
      )
    end
  end

  class GcpOperationTest < GcpTestCase
    def test_marks_manual_operation_first_payload
      record = normalized_record(
        event: "custom.started",
        source: "worker",
        execution: { type: "job", id: "job-1" },
        payload: GCP.operation(first: true)
      )

      formatted = formatted_record(record)

      assert_equal(
        { "id" => "job-1", "producer" => "worker", "first" => true },
        formatted.fetch("logging.googleapis.com/operation")
      )
      refute formatted.key?("payload")
    end

    def test_marks_manual_operation_without_execution
      record = normalized_record(
        event: "script.started",
        source: "script",
        payload: GCP.operation(id: "script-1", producer: "maintenance", first: true)
      )

      formatted = formatted_record(record)

      assert_equal(
        { "id" => "script-1", "producer" => "maintenance", "first" => true },
        formatted.fetch("logging.googleapis.com/operation")
      )
    end

    def test_does_not_infer_first_operation_from_event_name
      record = normalized_record(
        event: "request.started",
        execution: { type: "request", id: "request-1" }
      )

      formatted = formatted_record(record)

      refute formatted.fetch("logging.googleapis.com/operation").key?("first")
    end
  end

  class GcpTest < GcpTestCase # rubocop:disable Metrics/ClassLength -- Formatter shape matrix.
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

    def test_formats_trace_labels_without_http_request_on_point_records
      formatted = formatted_order_record

      assert_equal expected_trace_fields.merge(julewire_execution: false), trace_fields(formatted)
      refute formatted.key?("httpRequest")
    end

    def test_omits_internal_and_empty_julewire_fields
      formatted = formatted_order_record

      refute formatted.fetch("julewire").key?("carry")
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
      refute formatted.key?("payload")
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
      refute record.fetch(:execution).key?(:root)
    end

    def test_does_not_map_non_request_duration_to_http_latency
      record = normalized_record(
        event: "active_record.sql",
        payload: { duration_ms: 12.5, status: 200, path: "/orders" },
        metrics: { duration_ms: 12.5 }
      )

      formatted = formatted_record(record)

      refute formatted.key?("httpRequest")
    end

    def test_omits_empty_payload_and_julewire_fields
      record = normalized_record(message: nil, payload: {}, context: {})

      formatted = formatted_record(record)

      refute formatted.key?("message")
      refute formatted.key?("payload")
      refute formatted.fetch("julewire").key?("context")
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

    def test_omits_http_request_when_request_summary_has_no_http_fields
      record = normalized_record(kind: :summary, event: "request.completed")

      formatted = formatted_record(record)

      refute formatted.key?("httpRequest")
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

  class GcpLabelTest < GcpTestCase
    def test_shapes_labels_to_configured_provider_limits
      record = normalized_record(labels: { first: "123456", second: "ok", third: "drop" })

      formatted = formatted_record(record, formatter: GCP::Formatter.new(max_labels: 2, max_label_value_bytes: 5))

      assert_equal({ "first" => "12345", "second" => "ok" }, formatted.fetch("logging.googleapis.com/labels"))
    end

    def test_drops_labels_with_oversized_keys
      record = normalized_record(labels: { "too_long" => "drop", ok: "yes" })

      formatted = formatted_record(record, formatter: GCP::Formatter.new(max_label_key_bytes: 4))

      assert_equal({ "ok" => "yes" }, formatted.fetch("logging.googleapis.com/labels"))
    end
  end

  class GcpSourceLocationTest < GcpTestCase
    cover Julewire::GCP::SourceLocation

    def test_source_location_helper_omits_empty_input
      assert_nil GCP::SourceLocation.call({})
    end

    def test_source_location_helper_stringifies_values
      assert_equal(
        { "file" => "123", "line" => "42", "function" => "perform" },
        GCP::SourceLocation.call(file: 123, line: 42, function: :perform)
      )
    end

    def test_source_location_helper_omits_blank_values
      assert_nil GCP::SourceLocation.call(file: "", line: nil, function: "")
    end

    def test_source_location_helper_ignores_non_hash_errors
      assert_nil GCP::SourceLocation.from_error(Object.new)
    end

    def test_source_location_helper_ignores_errors_without_backtrace
      assert_nil GCP::SourceLocation.from_error(class: "RuntimeError")
    end

    def test_source_location_helper_accepts_hash_subclass_errors
      error = Class.new(Hash).new
      error[:backtrace] = ["/tmp/job.rb:9:in 'perform'"]

      assert_equal(
        { "file" => "/tmp/job.rb", "line" => "9", "function" => "perform" },
        GCP::SourceLocation.from_error(error)
      )
    end

    def test_source_location_helper_accepts_single_string_backtrace
      error = {
        backtrace: "/tmp/job.rb:9:in 'perform'"
      }

      assert_equal(
        { "file" => "/tmp/job.rb", "line" => "9", "function" => "perform" },
        GCP::SourceLocation.from_error(error)
      )
    end

    def test_source_location_helper_skips_invalid_backtrace_lines
      error = {
        backtrace: ["not a backtrace line", "/tmp/job.rb:9:in 'perform'"]
      }

      assert_equal(
        { "file" => "/tmp/job.rb", "line" => "9", "function" => "perform" },
        GCP::SourceLocation.from_error(error)
      )
    end

    def test_source_location_helper_ignores_non_string_backtrace_lines
      assert_nil GCP::SourceLocation.from_backtrace_line(nil)
    end

    def test_source_location_helper_coerces_backtrace_lines_to_strings
      line = Object.new
      line.define_singleton_method(:to_s) { "/tmp/job.rb:9:in 'perform'" }

      assert_equal(
        { "file" => "/tmp/job.rb", "line" => "9", "function" => "perform" },
        GCP::SourceLocation.from_backtrace_line(line)
      )
    end

    def test_source_location_helper_parses_plain_backtrace_function
      assert_equal(
        { "file" => "/tmp/job.rb", "line" => "9", "function" => "perform" },
        GCP::SourceLocation.from_backtrace_line("/tmp/job.rb:9:in perform")
      )
    end

    def test_maps_source_location_special_field
      record = normalized_record(
        payload: GCP.source_location(
          file: "app/jobs/import_job.rb",
          line: 42,
          function: "ImportJob#perform"
        )
      )

      formatted = formatted_record(record)

      assert_equal(
        {
          "file" => "app/jobs/import_job.rb",
          "line" => "42",
          "function" => "ImportJob#perform"
        },
        formatted.fetch("logging.googleapis.com/sourceLocation")
      )
      refute formatted.key?("payload")
    end

    def test_omits_invalid_source_location_line
      record = normalized_record(
        payload: {
          gcp: {
            source_location: { file: "worker.rb", line: "unknown" }
          }
        }
      )

      formatted = formatted_record(record)

      assert_equal({ "file" => "worker.rb" }, formatted.fetch("logging.googleapis.com/sourceLocation"))
    end

    def test_maps_neutral_source_location_attributes
      record = normalized_record(
        neutral: Core::Fields::AttributeKeys.fields(
          Core::Fields::AttributeKeys::CODE_FILE_PATH => "app/jobs/import_job.rb",
          Core::Fields::AttributeKeys::CODE_LINE_NUMBER => 42,
          Core::Fields::AttributeKeys::CODE_FUNCTION_NAME => "ImportJob#perform"
        )
      )

      formatted = formatted_record(record)

      assert_equal(
        {
          "file" => "app/jobs/import_job.rb",
          "line" => "42",
          "function" => "ImportJob#perform"
        },
        formatted.fetch("logging.googleapis.com/sourceLocation")
      )
    end

    def test_explicit_source_location_wins_over_neutral_attributes
      record = normalized_record(
        payload: GCP.source_location(file: "explicit.rb", line: 7),
        neutral: Core::Fields::AttributeKeys.fields(
          Core::Fields::AttributeKeys::CODE_FILE_PATH => "event.rb",
          Core::Fields::AttributeKeys::CODE_LINE_NUMBER => 12
        )
      )

      formatted = formatted_record(record)

      assert_equal({ "file" => "explicit.rb", "line" => "7" },
                   formatted.fetch("logging.googleapis.com/sourceLocation"))
    end

    def test_infers_source_location_from_error_backtrace
      record = normalized_record(
        error: {
          class: "RuntimeError",
          message: "boom",
          backtrace: ["/app/controllers/orders_controller.rb:12:in 'OrdersController#create'"]
        }
      )

      formatted = formatted_record(record)

      assert_equal(
        {
          "file" => "/app/controllers/orders_controller.rb",
          "line" => "12",
          "function" => "OrdersController#create"
        },
        formatted.fetch("logging.googleapis.com/sourceLocation")
      )
    end

    def test_explicit_source_location_wins_over_error_backtrace
      record = normalized_record(
        payload: GCP.source_location(file: "explicit.rb", line: 7),
        error: {
          class: "RuntimeError",
          message: "boom",
          backtrace: ["/app/controllers/orders_controller.rb:12:in 'OrdersController#create'"]
        }
      )

      formatted = formatted_record(record)

      assert_equal(
        {
          "file" => "explicit.rb",
          "line" => "7"
        },
        formatted.fetch("logging.googleapis.com/sourceLocation")
      )
    end
  end

  class GcpStackTraceTest < GcpTestCase
    cover Julewire::GCP::StackTrace

    def test_stack_trace_ignores_non_hash_input
      assert_nil GCP::StackTrace.call(Object.new)
    end

    def test_stack_trace_accepts_hash_subclass_input
      error = Class.new(Hash).new
      error[:class] = "RuntimeError"
      error[:message] = "boom"
      error[:backtrace] = ["/app/job.rb:9"]

      assert_equal "RuntimeError: boom\n/app/job.rb:9", GCP::StackTrace.call(error)
    end

    def test_stack_trace_ignores_empty_error
      assert_nil GCP::StackTrace.call({})
    end

    def test_stack_trace_compacts_nil_backtrace_lines
      assert_equal(
        "RuntimeError: boom\n/app/job.rb:9",
        GCP::StackTrace.call(
          class: "RuntimeError",
          message: "boom",
          backtrace: ["/app/job.rb:9", nil]
        )
      )
    end

    def test_stack_trace_prefixes_cause_lines
      assert_equal(
        "RuntimeError: boom\n/app/job.rb:9\nCaused by: ArgumentError: bad\n/app/cause.rb:3",
        GCP::StackTrace.call(
          error_shape(
            "RuntimeError",
            "boom",
            ["/app/job.rb:9"],
            cause: error_shape("ArgumentError", "bad", ["/app/cause.rb:3"])
          )
        )
      )
    end

    def test_stack_trace_accepts_hash_subclass_cause
      cause = Class.new(Hash).new
      cause[:class] = "ArgumentError"
      cause[:message] = "bad"
      cause[:backtrace] = ["/app/cause.rb:3"]

      assert_equal(
        "RuntimeError: boom\n/app/job.rb:9\nCaused by: ArgumentError: bad\n/app/cause.rb:3",
        GCP::StackTrace.call(
          class: "RuntimeError",
          message: "boom",
          backtrace: ["/app/job.rb:9"],
          cause: cause
        )
      )
    end

    def test_stack_trace_uses_cause_when_parent_has_no_backtrace
      assert_equal(
        "RuntimeError: boom\nCaused by: ArgumentError: bad\n/app/cause.rb:3",
        GCP::StackTrace.call(
          class: "RuntimeError",
          message: "boom",
          cause: {
            class: "ArgumentError",
            message: "bad",
            backtrace: ["/app/cause.rb:3"]
          }
        )
      )
    end

    def test_stack_trace_ignores_non_hash_cause
      assert_equal(
        "RuntimeError: boom\n/app/job.rb:9",
        GCP::StackTrace.call(
          class: "RuntimeError",
          message: "boom",
          backtrace: ["/app/job.rb:9"],
          cause: "not-a-hash"
        )
      )
    end

    def test_stack_trace_removes_backtraces_recursively
      value = {
        class: "RuntimeError",
        backtrace: ["top"],
        cause: {
          class: "ArgumentError",
          backtrace: ["cause"]
        },
        nested: [
          { backtrace: ["nested"], kept: true },
          "plain"
        ]
      }

      assert_equal(
        {
          class: "RuntimeError",
          cause: {
            class: "ArgumentError"
          },
          nested: [
            { kept: true },
            "plain"
          ]
        },
        GCP::StackTrace.remove_backtraces(value)
      )
    end
  end

  class GcpNonRequestSummaryTest < GcpTestCase
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

      refute formatted.key?("httpRequest")
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

      refute formatted.key?("httpRequest")
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
        assert formatted.fetch("logging.googleapis.com/trace_sampled")
      else
        refute formatted.fetch("logging.googleapis.com/trace_sampled")
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

    def legacy_trace_payload
      {
        request_headers: {
          "x-cloud-trace-context" => "06796866738c859f2f19b7cfb3214824/74;o=1"
        }
      }
    end
  end
  private_constant :GcpTraceHelpers

  class GcpTracePathTest < GcpTestCase
    include GcpTraceHelpers

    cover Julewire::GCP::ExecutionPayload
    cover Julewire::GCP::TraceContext
    cover Julewire::GCP::TraceContext::Traceparent

    def test_can_map_trace_fields_from_configured_paths
      record = normalized_record(context: configured_trace_context)

      formatted = formatted_context_trace_record(record)

      assert_trace_context(formatted)
    end

    def test_preserves_expanded_trace_resource_from_configured_path
      record = normalized_record(
        context: {
          cloud: configured_trace_context.fetch(:cloud).merge(
            trace_id: "projects/upstream-project/traces/06796866738c859f2f19b7cfb3214824"
          )
        }
      )

      formatted = formatted_context_trace_record(record)

      assert_equal "projects/upstream-project/traces/06796866738c859f2f19b7cfb3214824",
                   formatted.fetch("logging.googleapis.com/trace")
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

      refute formatted.key?("logging.googleapis.com/trace")
      assert_equal(
        {
          "type" => "job",
          "trace_id" => "06796866738c859f2f19b7cfb3214824",
          "span_id" => "000000000000004a",
          "sampled" => true,
          "correlation_id" => "corr-1"
        },
        formatted.fetch("julewire").fetch("execution")
      )
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

      refute formatted.key?("logging.googleapis.com/trace")
      assert_equal(
        { "type" => "job", "trace_id" => "", "correlation_id" => "corr-1" },
        formatted.fetch("julewire").fetch("execution")
      )
    end
  end

  class GcpTraceHeaderTest < GcpTestCase
    include GcpTraceHelpers

    cover Julewire::GCP::TraceContext
    cover Julewire::GCP::TraceContext::Traceparent

    def test_parses_x_cloud_trace_context_when_traceparent_is_missing
      record = normalized_record(payload: legacy_trace_payload)

      formatted = formatted_record(record, formatter: GCP::Formatter.new(project_id: "project-1"))

      assert_equal "projects/project-1/traces/06796866738c859f2f19b7cfb3214824",
                   formatted.fetch("logging.googleapis.com/trace")
      assert_equal "000000000000004a", formatted.fetch("logging.googleapis.com/spanId")
      assert formatted.fetch("logging.googleapis.com/trace_sampled")
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

      refute formatted.key?("logging.googleapis.com/trace")
      refute formatted.key?("logging.googleapis.com/spanId")
    end

    def test_allows_extra_traceparent_fields_for_future_versions
      formatted = formatted_trace_header_record(
        "traceparent",
        "01-06796866738c859f2f19b7cfb3214824-000000000000004a-01-extra"
      )

      assert_equal "projects/project-1/traces/06796866738c859f2f19b7cfb3214824",
                   formatted.fetch("logging.googleapis.com/trace")
      assert_equal "000000000000004a", formatted.fetch("logging.googleapis.com/spanId")
      assert formatted.fetch("logging.googleapis.com/trace_sampled")
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

      refute formatted.key?("logging.googleapis.com/trace")
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

      refute context.fetch(:trace_sampled)
    end

    def test_accepts_string_trace_sampled_path_values
      record = normalized_record(context: { cloud: configured_trace_context.fetch(:cloud).merge(sampled: "yes") })

      formatted = formatted_context_trace_record(record)

      assert formatted.fetch("logging.googleapis.com/trace_sampled")
    end

    def test_rejects_x_cloud_trace_context_span_ids_larger_than_uint64
      formatted = formatted_trace_header_record(
        "x-cloud-trace-context",
        "06796866738c859f2f19b7cfb3214824/18446744073709551616;o=1"
      )

      assert_equal "projects/project-1/traces/06796866738c859f2f19b7cfb3214824",
                   formatted.fetch("logging.googleapis.com/trace")
      refute formatted.key?("logging.googleapis.com/spanId")
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

        refute formatted.key?("logging.googleapis.com/trace"), traceparent
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

        refute formatted.key?("logging.googleapis.com/trace"), header
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
    include GcpTraceHelpers

    cover Julewire::GCP::TraceContext

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
      refute GCP::TraceContext.parse_x_cloud_trace_context(
        "06796866738c859f2f19b7cfb3214824/74;o=2"
      ).fetch(:trace_sampled)
      assert GCP::TraceContext.parse_x_cloud_trace_context(
        "06796866738c859f2f19b7cfb3214824/74;o=3"
      ).fetch(:trace_sampled)
      refute GCP::TraceContext.parse_x_cloud_trace_context(
        "06796866738c859f2f19b7cfb3214824/74;o=10"
      ).fetch(:trace_sampled)
    end

    def test_x_cloud_trace_context_parses_sampled_option_as_decimal
      assert GCP::TraceContext.parse_x_cloud_trace_context(
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

  class GcpIntegrationTest < Minitest::Test
    def test_integrates_as_core_destination_formatter
      output = StringIO.new

      Julewire.configure do |config|
        config.destinations.use(:gcp, formatter: GCP::Formatter.new, output: output)
      end

      Julewire.emit(severity: :info, message: "hello", payload: { value: 1 })

      parsed = JSON.parse(output.string)

      assert_equal "INFO", parsed.fetch("severity")
      assert_equal "hello", parsed.fetch("message")
      assert_equal 1, parsed.fetch("payload").fetch("value")
    end
  end
end
