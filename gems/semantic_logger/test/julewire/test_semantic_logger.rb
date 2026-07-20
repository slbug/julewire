# frozen_string_literal: true

require "test_helper"
require "json"

module Julewire
  class TestSemanticLogger < Minitest::Test
    cover Julewire::SemanticLogger::Destination
    cover Julewire::SemanticLogger::Transport
    def test_destination_implements_julewire_destination_lifecycle
      destination = SemanticLogger::Destination.new(
        name: :semantic_logger,
        formatter: :to_h.to_proc,
        io: StringIO.new,
        async: false
      )

      record = Core::Records::Draft.build(
        { event: "test.event", source: "test", message: "test" },
        context: nil,
        scope: nil
      ).to_record

      assert_nil destination.emit(record)
      assert_true destination.flush(timeout: 0)
      assert_true destination.close(timeout: 0)
      assert_kind_of Hash, destination.health
    end

    def test_destination_emits_execution_point_and_summary
      io = StringIO.new
      traceparent = "00-06796866738c859f2f19b7cfb3214824-000000000000004a-01"

      Julewire.configure do |config|
        config.destinations.use(
          :semantic_logger,
          formatter: :to_h.to_proc,
          io: io,
          async: false
        )
      end
      Julewire.with_execution(type: :contract, id: "contract-1", summary_event: "contract.completed") do
        Julewire.context.add(request_id: "request-1")
        Julewire.carry.add(http: { request_headers: { traceparent: traceparent } })
        Julewire.summary.add(total: 2)
        Julewire.emit(event: "contract.point", source: "contract", message: "point", payload: { value: 1 })
      end
      Julewire.flush

      records = io.string.lines.map { JSON.parse(it) }
      point = records.find { it.fetch("event") == "contract.point" }
      summary = records.find { it.fetch("event") == "contract.completed" }

      assert_equal "point", point.fetch("message")
      assert_equal "request-1", point.dig("context", "request_id")
      assert_equal traceparent, point.dig("carry", "http", "request_headers", "traceparent")
      assert_equal 2, summary.dig("payload", "total")
      assert_equal "semantic_logger_destination",
                   Julewire.health.dig(:pipeline, :destinations, :semantic_logger, :type)
      assert_equal "summary", summary.fetch("kind")
    end

    def test_destination_failure_is_contained_and_reported
      Julewire.configure do |config|
        config.destinations.use(
          :semantic_logger,
          formatter: ->(_record) { raise "format failed" },
          io: StringIO.new,
          async: false
        )
      end

      assert_nil Julewire.emit(event: "semantic_logger.failure", source: "test")

      destination_health = Julewire.health.dig(:pipeline, :destinations, :semantic_logger)

      assert_equal :degraded, destination_health.fetch(:status)
      assert_equal 1, destination_health.dig(:counts, :failed)
    end

    def test_destination_factory_preserves_local_callbacks
      failures = Queue.new
      drops = Queue.new

      Julewire.configure do |config|
        config.destinations.use(
          :semantic_logger,
          formatter: ->(_record) { raise "format failed" },
          io: StringIO.new,
          async: false,
          on_drop: ->(reason, metadata) { drops << [reason, metadata] },
          on_failure: ->(error, metadata) { failures << [error, metadata] }
        )
      end

      Julewire.emit(message: "lost")

      error, failure_metadata = safe_queue_pop(failures)
      reason, drop_metadata = safe_queue_pop(drops)

      assert_equal "format failed", error.message
      assert_equal :destination, failure_metadata.fetch(:phase)
      assert_equal :semantic_logger, failure_metadata.fetch(:destination)
      assert_equal :destination_exception, reason
      assert_equal :semantic_logger, drop_metadata.fetch(:destination)
      assert_equal :info, drop_metadata.dig(:record_metadata, :severity)
    end

    def test_destination_callback_failures_are_reported_in_health
      Julewire.configure do |config|
        config.destinations.use(
          :semantic_logger,
          formatter: ->(_record) { raise "format failed" },
          io: StringIO.new,
          async: false,
          on_drop: ->(*) { raise "drop callback failed" },
          on_failure: ->(*) { raise "failure callback failed" }
        )
      end

      Julewire.emit(message: "lost")

      health = Julewire.health.dig(:pipeline, :destinations, :semantic_logger)

      assert_equal 2, health.dig(:counts, :callback_error)
      assert_equal "RuntimeError", health.dig(:last_callback_failure, :class)
      assert_equal :semantic_logger, health.dig(:last_callback_failure, :destination)
    end
  end
end
