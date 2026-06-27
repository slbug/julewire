# frozen_string_literal: true

require "test_helper"
require "support/gcp_test_case"

module Julewire
  class GcpContractTest < GcpTestCase
    cover "Julewire::GCP::Formatter#append_log_field"
    cover "Julewire::GCP::Formatter#append_special_fields"
    cover "Julewire::GCP::Formatter#call"
    cover "Julewire::GCP::Formatter#initialize"
    cover "Julewire::GCP::Formatter#julewire_payload"
    cover "Julewire::GCP::Formatter#operation"
    cover "Julewire::GCP::Formatter#trace"
    cover "Julewire::GCP::Formatter#true_value?"
    cover "Julewire::GCP::LogEncoder.call"
    cover "Julewire::GCP::LogEncoder.formatter"
    cover "Julewire::GCP::LogEncoder.json_encoder"
    def test_formatter_produces_json_encodable_gcp_record
      formatted = GCP::Formatter.new.call(
        normalized_record(event: "test.event", source: "test", message: "test message", payload: { value: 1 })
      )
      encoded = JSON.parse(Core::Serialization::JsonEncoder.new.call(formatted))

      assert_equal "test.event", encoded.fetch("julewire").fetch("event")
    end

    def test_log_encoder_formats_and_encodes_gcp_json
      encoded = GCP::LogEncoder.call(normalized_record(event: "encoder.event", message: "encoded"))
      parsed = JSON.parse(encoded)

      assert_equal "encoder.event", parsed.fetch("julewire").fetch("event")
      assert_equal "encoded", parsed.fetch("message")
    end

    def test_formatter_rejects_non_record_input
      error = assert_raises(TypeError) { GCP::Formatter.new.call({}) }

      assert_equal "expected Julewire::Record", error.message
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
        JSON.parse(File.read(File.expand_path("../fixtures/gcp/request_summary.json", __dir__))),
        formatted_record(record, formatter: GCP::Formatter.new(project_id: "project-1"))
      )
    end

    def test_gcp_destination_emits_execution_point_and_summary
      output = StringIO.new
      traceparent = "00-06796866738c859f2f19b7cfb3214824-000000000000004a-01"

      Julewire.configure do |config|
        config.destinations.add(
          GCP::Destination.new(
            formatter: GCP::Formatter.new(project_id: "project-1"),
            output: output
          )
        )
      end
      Julewire.with_execution(type: :contract, id: "contract-1", summary_event: "contract.completed") do
        Julewire.context.add(request_id: "request-1")
        Julewire.carry.add(http: { request_headers: { traceparent: traceparent } })
        Julewire.summary.add(total: 2)
        Julewire.emit(event: "contract.point", source: "contract", message: "point", payload: { value: 1 })
      end
      Julewire.flush

      records = output.string.lines.map { JSON.parse(it) }
      point = records.find { it.dig("julewire", "event") == "contract.point" }
      summary = records.find { it.dig("julewire", "event") == "contract.completed" }

      assert_equal "request-1", point.dig("julewire", "context", "request_id")
      assert_equal 2, summary.dig("payload", "total")
      assert_runtime_output(point, summary, Julewire.health)
    end

    private

    def assert_runtime_output(point, summary, health)
      assert_equal(expected_runtime_output, runtime_output(point, summary, health))
    end

    def expected_runtime_output
      {
        trace: "projects/project-1/traces/06796866738c859f2f19b7cfb3214824",
        span: "000000000000004a",
        sampled: true,
        configured: true,
        summary_kind: "summary"
      }
    end

    def runtime_output(point, summary, health)
      {
        trace: point.fetch("logging.googleapis.com/trace"),
        span: point.fetch("logging.googleapis.com/spanId"),
        sampled: point.fetch("logging.googleapis.com/trace_sampled"),
        configured: health.dig(:pipeline, :configured),
        summary_kind: summary.dig("julewire", "kind")
      }
    end
  end

  class GcpDestinationTest < GcpTestCase
    cover Julewire::GCP::Destination
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

    def test_destination_keeps_record_size_configurable
      output = StringIO.new

      Julewire.configure do |config|
        config.destinations.add(GCP::Destination.new(output: output, max_record_bytes: 16))
      end
      Julewire.emit(message: "too large")

      assert_empty output.string
      assert_equal 1, Julewire.health.dig(:pipeline, :destinations, :gcp, :counts, :record_too_large)
    end

    def test_destination_uses_default_gcp_record_size_limit
      output = StringIO.new
      destination = GCP::Destination.new(output: output)
      labels = 20.times.to_h { |index| [:"label_#{index}", "x" * GCP::DEFAULT_MAX_LABEL_VALUE_BYTES] }

      destination.emit(owned_record(labels: labels))

      assert_empty output.string
      assert_equal 1, destination.health.dig(:counts, :record_too_large)
    end

    def test_destination_does_not_close_output_by_default
      output = StringIO.new
      destination = GCP::Destination.new(output: output)

      destination.close

      refute_predicate output, :closed?
    end

    def test_destination_closes_owned_output
      output = StringIO.new
      destination = GCP::Destination.new(output: output, close_output: true)

      destination.close

      assert_predicate output, :closed?
    end

    def test_destination_passes_local_drop_callback
      drops = []
      destination = GCP::Destination.new(
        output: StringIO.new,
        max_record_bytes: 16,
        on_drop: ->(reason, metadata) { drops << [reason, metadata.fetch(:destination)] }
      )

      destination.emit(normalized_record(message: "too large"))

      assert_equal [%i[record_too_large gcp]], drops
    end

    def test_destination_passes_local_failure_callback
      failures = []
      error = RuntimeError.new("formatter failed")
      formatter = ->(_record) { raise error }
      destination = GCP::Destination.new(
        output: StringIO.new,
        formatter: formatter,
        on_failure: ->(failure, metadata) { failures << [failure, metadata.fetch(:phase)] }
      )

      destination.emit(normalized_record)

      assert_equal [[error, :formatter]], failures
    end
  end

  class GcpLabelFormatterValidationTest < GcpTestCase
    cover Julewire::GCP::LabelFormatter
    def test_formatter_validates_label_count_limit
      assert_equal(
        "max_labels must be a positive Integer",
        assert_raises(ArgumentError) { GCP::Formatter.new(max_labels: 0) }.message
      )
    end

    def test_formatter_validates_label_key_byte_limit
      assert_equal(
        "max_label_key_bytes must be nil or a positive Integer",
        assert_raises(ArgumentError) { GCP::Formatter.new(max_label_key_bytes: 0) }.message
      )
    end

    def test_formatter_validates_label_value_byte_limit
      assert_equal(
        "max_label_value_bytes must be nil or a positive Integer",
        assert_raises(ArgumentError) { GCP::Formatter.new(max_label_value_bytes: 0) }.message
      )
    end
  end

  class GcpFormatterOptionsTest < GcpTestCase
    cover "Julewire::GCP::Formatter#initialize"
    cover "Julewire::GCP::FormatterOptions.validate!"
    def test_formatter_rejects_unknown_options
      error = assert_raises(ArgumentError) { GCP::Formatter.new(nope: true) }

      assert_equal "unknown formatter options: nope", error.message
    end
  end

  class GcpFormatterInitializationTest < GcpTestCase
    cover "Julewire::GCP::Formatter#append_payload_fields"
    cover "Julewire::GCP::Formatter#frozen_service_context"
    cover "Julewire::GCP::Formatter#initialize"
    def test_formatter_snapshots_service_context
      service_context = { service: "api", version: "1" }
      formatter = GCP::Formatter.new(service_context: service_context)
      service_context[:version] = "2"

      formatted = formatted_record(formatter: formatter)

      assert_equal({ "service" => "api", "version" => "1" }, formatted.fetch("serviceContext"))
    end
  end

  class GcpOperationPayloadBuilderTest < GcpTestCase
    cover "Julewire::GCP.operation"
    def test_builds_manual_operation_marker_payload
      assert_equal({ gcp: { operation: {} } }, GCP.operation)
      assert_equal(
        { gcp: { operation: { id: "script-1", producer: "script", first: true, last: true } } },
        GCP.operation(id: "script-1", producer: "script", first: true, last: true)
      )
    end
  end

  class GcpSourceLocationPayloadBuilderTest < GcpTestCase
    cover "Julewire::GCP.source_location"
    def test_builds_manual_source_location_payload
      assert_equal(
        { gcp: { source_location: { file: "app/jobs/import_job.rb", line: 42, function: "ImportJob#perform" } } },
        GCP.source_location(file: "app/jobs/import_job.rb", line: 42, function: "ImportJob#perform")
      )
    end

    def test_builds_partial_manual_source_location_payload
      assert_equal({ gcp: { source_location: { file: "worker.rb" } } }, GCP.source_location(file: "worker.rb"))
      assert_equal({ gcp: { source_location: { line: 12 } } }, GCP.source_location(line: 12))
      assert_equal({ gcp: { source_location: { function: "Job#perform" } } },
                   GCP.source_location(function: "Job#perform"))
    end
  end

  class GcpOperationTest < GcpTestCase
    cover "Julewire::GCP::Formatter#application_payload"
    cover "Julewire::GCP::Formatter#call"
    cover "Julewire::GCP::Formatter#operation"
    cover "Julewire::GCP::Formatter#operation_options"
    cover "Julewire::GCP::Formatter#true_value?"
    cover Julewire::GCP::ExecutionPayload
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
      assert_false formatted.key?("payload")
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

      assert_false formatted.fetch("logging.googleapis.com/operation").key?("first")
    end

    def test_omits_operation_when_lineage_root_has_no_id
      base = normalized_record(event: "job.completed", execution: { type: "job" })
      data = base.to_h
      data[:execution] = data.fetch(:execution).except(:id, :root)
      lineage = Core::Execution::Lineage.new(root_reference: { type: "request" })
      record = Core::Records::Record.from_normalized_hash(data, lineage: lineage)

      formatted = formatted_record(record)

      assert_false formatted.key?("logging.googleapis.com/operation")
    end
  end
end
