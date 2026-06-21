# frozen_string_literal: true

require "test_helper"

module Julewire
  module GCP
    class TestCLILogDecoder < Minitest::Test
      Result = Data.define(:status, :stdout, :stderr)

      def test_tail_renders_gcp_shaped_julewire_json_lines_with_explicit_format
        result = run_cli(%w[tail --format gcp -], input: "#{gcp_line}\n")

        assert_equal 0, result.status
        assert_empty result.stderr
        assert_includes result.stdout, "ERROR"
        assert_includes result.stdout, "event=request.completed"
        assert_includes result.stdout, "source=rails"
        assert_includes result.stdout, "RuntimeError: 123"
        assert_includes result.stdout, "\"process_pid\":\"123\""
      end

      def test_tail_auto_uses_registered_gcp_decoder
        result = run_cli(%w[tail -], input: "#{gcp_line}\n")

        assert_equal 0, result.status
        assert_empty result.stderr
        assert_includes result.stdout, "event=request.completed"
      end

      def test_transcode_decodes_gcp_logs_to_core_json
        result = run_cli(%w[transcode --from gcp --to core -], input: "#{gcp_line}\n")

        assert_equal 0, result.status
        assert_empty result.stderr
        payload = JSON.parse(result.stdout)

        assert_equal "request.completed", payload.fetch("event")
        assert_equal "rails", payload.fetch("source")
        assert_equal({ "process_pid" => "123" }, payload.fetch("labels"))
        assert_equal({ "worker_pid" => 456 }, payload.fetch("payload"))
        refute payload.key?("logging.googleapis.com/labels")
      end

      def test_transcode_encodes_core_logs_as_gcp_json
        result = run_cli(%w[transcode --from core --to gcp -], input: "#{core_line}\n")

        assert_equal 0, result.status
        assert_empty result.stderr
        payload = JSON.parse(result.stdout)

        assert_equal "INFO", payload.fetch("severity")
        assert_equal "job.completed", payload.dig("julewire", "event")
        assert_equal "ImportJob finished", payload.fetch("message")
      end

      def test_gcp_log_format_round_trips_provider_owned_sections
        encoded = Core::CLI::LogFormats.encode(gcp_round_trip_record, format: :gcp)
        decoded = Core::CLI::LogFormats.decode(JSON.parse(encoded), format: :gcp)

        assert_equal "request.completed", decoded.fetch(:event)
        assert_equal "rails", decoded.fetch(:source)
        assert_equal({ type: "request" }, decoded.fetch(:execution))
        assert_equal({ request_id: "req-1" }, decoded.fetch(:context))
        assert_equal({ rails: { status: 500 } }, decoded.fetch(:attributes))
        assert_equal({ process_pid: "123" }, decoded.fetch(:labels))
        assert_equal({ worker_pid: 456 }, decoded.fetch(:payload))
        assert_equal({ duration_ms: 10.5 }, decoded.fetch(:metrics))
        assert_equal({ class: "RuntimeError", message: "123" }, decoded.fetch(:error))
      end

      private

      def gcp_round_trip_record
        Core::Records::Draft.build(gcp_round_trip_input, context: {}, scope: nil).to_record
      end

      def gcp_round_trip_input
        {
          severity: :error,
          kind: :summary,
          event: "request.completed",
          message: "GET /probe -> 500",
          source: "rails",
          execution: { type: "request", id: "request-1" },
          context: { request_id: "req-1" },
          attributes: { rails: { status: 500 } },
          labels: { process_pid: "123" },
          payload: { worker_pid: 456 },
          metrics: { duration_ms: 10.5 },
          error: { class: "RuntimeError", message: "123" }
        }
      end

      def run_cli(argv, input:)
        stdout = StringIO.new
        stderr = StringIO.new
        status = Julewire::Core::CLI.call(
          argv: argv,
          stdin: StringIO.new(input),
          stdout: stdout,
          stderr: stderr
        )
        Result.new(status: status, stdout: stdout.string, stderr: stderr.string)
      end

      def gcp_line
        JSON.generate(
          "severity" => "ERROR",
          "time" => "2026-06-19T10:00:00Z",
          "message" => "RuntimeError: 123",
          "logging.googleapis.com/labels" => { "process_pid" => "123" },
          "payload" => { "worker_pid" => 456 },
          "julewire" => {
            "kind" => "summary",
            "event" => "request.completed",
            "source" => "rails",
            "execution" => { "type" => "request" },
            "context" => { "request_id" => "req-1" },
            "error" => { "class" => "RuntimeError", "message" => "123" },
            "metrics" => { "duration_ms" => 10.5 }
          }
        )
      end

      def core_line
        JSON.generate(
          "timestamp" => "2026-06-19T10:00:00Z",
          "severity" => "info",
          "kind" => "summary",
          "event" => "job.completed",
          "message" => "ImportJob finished",
          "source" => "test",
          "execution" => { "type" => "job" },
          "context" => {},
          "attributes" => {},
          "metrics" => { "duration_ms" => 12.5 }
        )
      end
    end
  end
end
