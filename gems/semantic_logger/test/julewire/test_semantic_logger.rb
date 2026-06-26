# frozen_string_literal: true

require "test_helper"
require "json"

module Julewire
  class TestSemanticLogger < Minitest::Test
    cover Julewire::SemanticLogger::Destination

    def test_that_it_has_a_version_number
      refute_nil SemanticLogger::VERSION
    end

    def test_destination_satisfies_julewire_destination_contract
      destination = SemanticLogger::Destination.new(
        name: :semantic_logger,
        formatter: :to_h.to_proc,
        io: StringIO.new,
        async: false
      )

      assert_julewire_destination_contract(destination)
    end

    def test_destination_satisfies_julewire_runtime_integration_contract
      io = StringIO.new

      point, summary, health = assert_julewire_runtime_integration_contract(
        configure: lambda do |config|
          config.destinations.use(
            :semantic_logger,
            formatter: :to_h.to_proc,
            io: io,
            async: false
          )
        end,
        records: -> { io.string.lines.map { JSON.parse(it) } },
        event_path: %w[event],
        context_path: %w[context],
        carry_path: %w[carry],
        summary_payload_path: %w[payload],
        destination_name: :semantic_logger
      )

      assert_equal "point", point.fetch("message")
      assert_equal "semantic_logger_destination", health.dig(:pipeline, :destinations, :semantic_logger, :type)
      assert_equal "summary", summary.fetch("kind")
    end

    def test_destination_satisfies_julewire_failure_containment_contract
      _health, destination_health = assert_julewire_failure_containment_contract(
        configure: lambda do |config|
          config.destinations.use(
            :semantic_logger,
            formatter: ->(_record) { raise "format failed" },
            io: StringIO.new,
            async: false
          )
        end,
        destination_name: :semantic_logger
      )

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

      error, failure_metadata = failures.pop
      reason, drop_metadata = drops.pop

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
