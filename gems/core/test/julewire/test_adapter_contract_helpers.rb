# frozen_string_literal: true

require "test_helper"
require "json"
require "stringio"

module Julewire
  class TestAdapterContractHelpers < Minitest::Test
    def test_processor_contract_helper_accepts_draft_mutating_processor
      processor = lambda do |record|
        record[:payload][:processed] = true
        nil
      end

      result = assert_julewire_processor_contract(processor)

      assert result.dig(:payload, :processed)
    end

    def test_record_draft_transform_contract_helper_exercises_transform_api
      draft = assert_julewire_record_draft_transform_contract

      assert_equal "test message transformed", draft.fetch(:message)
      assert_equal "yes", draft.dig(:labels, :record_transformed)
    end

    def test_processor_contract_helper_treats_nil_as_unchanged_record
      processor = ->(_record) {}

      result = assert_julewire_processor_contract(processor)

      assert_equal "test.event", result[:event]
    end

    def test_shared_spi_contract_helpers_exercise_core_spi
      assert_julewire_integration_spi_contract
      assert_julewire_validation_spi_contract
      assert_julewire_truncation_marker_spi_contract
      assert_julewire_bounded_transform_spi_contract
    end

    def test_formatter_contract_helper_accepts_json_encoder_safe_formatter
      formatter = ->(record) { { event: record.fetch(:event), payload: record.fetch(:payload), nan: Float::NAN } }

      formatted = assert_julewire_formatter_contract(formatter)

      assert_equal "test.event", formatted.fetch(:event)
    end

    def test_destination_contract_helper_exercises_lifecycle_truthiness
      destination = ContractDestination.new

      assert_same destination, assert_julewire_destination_contract(destination)
      assert_predicate destination, :emitted?
      assert_predicate destination, :flushed?
      assert_predicate destination, :closed?
    end

    def test_record_shape_contract_helper_pins_projection_and_serialization_shape
      record = assert_julewire_record_shape_contract

      assert_equal "visible", record.dig(:execution, :custom)
      assert_equal contract_traceparent, record.dig(:carry, :http, :request_headers, :traceparent)
    end

    def test_propagation_contract_helper_exercises_carrier_round_trip
      extracted = assert_julewire_propagation_contract(key: :julewire)

      assert_equal "request-1", extracted.dig(:context, :request_id)
      assert_equal "contract-1", extracted.dig(:execution, :id)
    end

    def test_runtime_integration_contract_helper_exercises_pipeline_shape
      output = StringIO.new
      formatter = :to_h.to_proc

      point, summary, health = assert_julewire_runtime_integration_contract(
        configure: ->(config) { configure_destination(config, formatter: formatter, output: output) },
        records: -> { output.string.lines.map { JSON.parse(it) } },
        event_path: %w[event],
        context_path: %w[context],
        carry_path: %w[carry],
        summary_payload_path: %w[payload]
      )

      assert_equal "point", point.fetch("message")
      assert_equal "contract", summary.fetch("source")
      assert_equal :ok, health.fetch(:status)
    end

    def test_record_source_contract_helper_checks_source_logger_kind
      records = [
        { "kind" => "point", "event" => "framework.event", "source" => "web", "logger" => "framework.event" },
        { "kind" => "summary", "event" => "request.completed", "source" => "web" }
      ]

      record = assert_julewire_record_source_contract(
        records: records,
        event: "framework.event",
        source: "web",
        logger: "framework.event",
        kind: "point"
      )

      assert_equal "framework.event", record.fetch("event")
    end

    def test_failure_containment_contract_helper_exercises_health_shape
      _health, destination_health = assert_julewire_failure_containment_contract(
        configure: lambda do |config|
          configure_destination(config, formatter: ->(_record) { raise "format failed" }, output: StringIO.new)
        end
      )

      assert_equal :degraded, destination_health.fetch(:status)
      assert_equal "RuntimeError", destination_health.dig(:last_failure, :class)
      assert_equal :formatter_error, destination_health.dig(:last_loss, :reason)
    end

    def test_execution_boundary_contract_helper_exercises_wrapped_work
      output = StringIO.new
      formatter = :to_h.to_proc

      point, summary, health = assert_julewire_execution_boundary_contract(
        configure: ->(config) { configure_destination(config, formatter: formatter, output: output) },
        exercise: method(:exercise_core_boundary_contract),
        records: -> { output.string.lines.map { JSON.parse(it) } },
        event_path: %w[event],
        context_path: %w[context],
        carry_path: %w[carry],
        summary_payload_path: %w[payload]
      )

      assert_equal "point", point.fetch("message")
      assert_equal "contract", summary.fetch("source")
      assert_equal :ok, health.fetch(:status)
    end

    def exercise_core_boundary_contract(emit_point:, add_summary:, context:, carry:, summary_event:, **)
      Julewire.with_execution(
        type: :contract,
        id: "contract-1",
        summary_event: summary_event,
        summary_source: "contract"
      ) do
        Julewire.context.add(context)
        Julewire.carry.add(carry)
        add_summary.call
        emit_point.call
      end
    end

    def test_processor_contract_helper_ignores_ordinary_return_values
      processor = :to_h.to_proc

      result = assert_julewire_processor_contract(processor)

      assert_instance_of Julewire::Core::Records::Draft, result
    end

    class ContractDestination
      def initialize
        @emitted = false
        @flushed = false
        @closed = false
      end

      def name = :contract

      def emit(record)
        Julewire::Core::Records::Record.validate_normalized!(record)
        @emitted = true
        nil
      end

      def flush(timeout:)
        @flushed = timeout.zero?
      end

      def close(timeout:)
        @closed = timeout.zero?
      end

      def health
        { status: :ok }
      end

      def emitted? = @emitted

      def flushed? = @flushed

      def closed? = @closed
    end
  end
end
