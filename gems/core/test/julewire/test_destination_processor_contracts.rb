# frozen_string_literal: true

require "test_helper"
require "json"
require "stringio"

module Julewire
  class TestDestinationProcessorContracts < Minitest::Test
    cover Julewire::Core::Destinations::ProcessorHandling
    cover "Julewire::Core::Processing::ProcessorChain*"
    cover Julewire::Core::Processing::ProcessorRegistry
    def test_destination_processors_report_unsupported_return_values
      default_output = StringIO.new
      audit_output = StringIO.new
      failures = Queue.new

      configure_destinations(
        default_output,
        audit_output,
        processors: ->(_draft) { "ignored" },
        on_failure: ->(error, metadata) { failures << [error, metadata] }
      )

      Julewire.emit(message: "work")

      health = Julewire.health.dig(:pipeline, :destinations, :audit)
      error, metadata = safe_queue_pop(failures)

      assert_equal({ "line" => "default:work" }, JSON.parse(default_output.string))
      assert_equal({ "line" => "audit:work" }, JSON.parse(audit_output.string))
      assert_equal 1, health.dig(:counts, :processor_invalid)
      assert_equal :destination_processor_result, health.dig(:last_failure, :phase)
      assert_equal "ArgumentError", health.dig(:last_failure, :class)
      assert_equal "Proc", health.dig(:last_failure, :processor)
      assert_equal "String", health.dig(:last_failure, :result_class)
      assert_equal "log", health.dig(:last_failure, :record, :event)
      assert_equal :info, health.dig(:last_failure, :record, :severity)
      assert_instance_of ArgumentError, error
      assert_equal "destination processor returned unsupported result", error.message
      assert_equal :destination_processor_result, metadata.fetch(:phase)
      assert_equal "Proc", metadata.fetch(:processor)
      assert_equal "String", metadata.fetch(:result_class)
    end

    def test_destination_processors_treat_nil_as_noop
      default_output = StringIO.new
      audit_output = StringIO.new

      configure_destinations(default_output, audit_output, processors: ->(_draft) {})

      Julewire.emit(message: "work")

      health = Julewire.health.dig(:pipeline, :destinations, :audit)

      assert_equal({ "line" => "default:work" }, JSON.parse(default_output.string))
      assert_equal({ "line" => "audit:work" }, JSON.parse(audit_output.string))
      assert_equal 0, health.dig(:counts, :processor_error)
      assert_equal 0, health.dig(:counts, :processor_invalid)
    end

    def test_destinations_without_processors_share_original_record
      default_output = StringIO.new
      audit_output = StringIO.new
      default_record = nil
      audit_record = nil

      Julewire.configure do |config|
        config.destinations.use(
          :default,
          formatter: lambda do |record|
            default_record = record
            { line: "default" }
          end,
          output: default_output
        )
        config.destinations.use(
          :audit,
          formatter: lambda do |record|
            audit_record = record
            { line: "audit" }
          end,
          output: audit_output,
          processors: []
        )
      end

      Julewire.emit(message: "work")

      assert_same default_record, audit_record
    end

    def test_destination_processors_report_raised_errors
      default_output = StringIO.new
      audit_output = StringIO.new
      observed_class = nil

      configure_destinations(
        default_output,
        audit_output,
        formatter: lambda { |record|
          observed_class = record.class
          { line: "audit:#{record.fetch(:message)}", payload: record.fetch(:payload) }
        },
        processors: ->(_draft) { raise "audit failed" }
      )

      Julewire.emit(message: "work")

      health = Julewire.health.dig(:pipeline, :destinations, :audit)

      assert_equal({ "line" => "default:work" }, JSON.parse(default_output.string))
      audit_record = JSON.parse(audit_output.string)

      assert_equal "audit:Julewire processor failed", audit_record.fetch("line")
      assert_equal "Proc", audit_record.dig("payload", "processor")
      assert_same Julewire::Core::Records::Record, observed_class
      assert_equal 1, health.dig(:counts, :processor_error)
      assert_equal :destination_processor, health.dig(:last_failure, :phase)
      assert_equal "RuntimeError", health.dig(:last_failure, :class)
      assert_equal "log", health.dig(:last_failure, :record, :event)
    end

    def test_destination_processors_drop_records
      default_output = StringIO.new
      audit_output = StringIO.new
      later_processor_called = false

      configure_destinations(
        default_output,
        audit_output,
        processors: [
          ->(_draft) { :drop },
          ->(_draft) { later_processor_called = true }
        ]
      )

      Julewire.emit(message: "work")

      health = Julewire.health.dig(:pipeline, :destinations, :audit)

      assert_equal({ "line" => "default:work" }, JSON.parse(default_output.string))
      assert_empty audit_output.string
      assert_false later_processor_called
      assert_equal 1, health.dig(:counts, :processor_dropped)
      assert_nil health.fetch(:last_failure)
    end

    def test_destination_processors_receive_mutable_drafts
      default_output = StringIO.new
      audit_output = StringIO.new
      observed_classes = []

      formatter = lambda do |record|
        observed_classes << record.class
        { payload: record.fetch(:payload) }
      end
      Julewire.configure do |config|
        config.destinations.use(:default, formatter: formatter, output: default_output)
        config.destinations.use(
          :audit,
          formatter: formatter,
          output: audit_output,
          processors: ->(draft) { draft.fetch(:payload)[:destination_only] = "audit" }
        )
      end

      Julewire.emit(payload: { original: "kept" })

      assert_equal({ "payload" => { "original" => "kept" } }, JSON.parse(default_output.string))
      assert_equal(
        { "payload" => { "destination_only" => "audit", "original" => "kept" } },
        JSON.parse(audit_output.string)
      )
      assert_equal [Julewire::Core::Records::Record, Julewire::Core::Records::Record], observed_classes
      assert_equal 0, destination_health(:audit).dig(:counts, :processor_error)
    end

    def test_destination_processor_corruption_is_attributed_before_conversion
      default_output = StringIO.new
      audit_output = StringIO.new
      failures = Queue.new

      configure_destinations(
        default_output,
        audit_output,
        on_failure: ->(error, metadata) { failures << [error, metadata] },
        processors: lambda { |draft|
          draft.transform_record! { it.merge(severity: :invalid) }
        }
      )

      Julewire.emit(message: "work")

      error, metadata = safe_queue_pop(failures)
      health = destination_health(:audit)

      assert_equal({ "line" => "default:work" }, JSON.parse(default_output.string))
      assert_empty audit_output.string
      assert_instance_of TypeError, error
      assert_equal :destination_processor_data, metadata.fetch(:phase)
      assert_equal "Proc", metadata.fetch(:processor)
      assert_equal "log", metadata.dig(:record_metadata, :event)
      assert_equal 1, health.dig(:counts, :processor_invalid)
      assert_equal 1, health.dig(:counts, :processor_dropped)
      assert_equal :destination_processor_data, health.dig(:last_failure, :phase)
      assert_equal "TypeError", health.dig(:last_failure, :class)
      assert_equal "Proc", health.dig(:last_failure, :processor)
      assert_equal "log", health.dig(:last_failure, :record, :event)
    end

    def test_destination_processors_honor_fail_open_policy
      default_output = StringIO.new
      audit_output = StringIO.new

      Julewire.configure do |config|
        config.destinations.use(
          :default,
          formatter: Julewire::Core::TestHelpers::TestLineFormatter.new("default"),
          output: default_output
        )
        config.destinations.use(
          :audit,
          formatter: Julewire::Core::TestHelpers::TestLineFormatter.new("audit"),
          output: audit_output,
          processors: Julewire::Core::Processing::ProcessorRegistry.new.tap do |processors|
            processors.use(->(_draft) { raise "ignored" }, on_error: :fail_open)
            processors.use(->(draft) { draft[:message] = "continued" })
          end
        )
      end

      Julewire.emit(message: "work")

      assert_equal({ "line" => "default:work" }, JSON.parse(default_output.string))
      assert_equal({ "line" => "audit:continued" }, JSON.parse(audit_output.string))
      assert_equal 1, destination_health(:audit).dig(:counts, :processor_error)
    end

    private

    def configure_destinations(
      default_output,
      audit_output,
      processors:,
      formatter: Julewire::Core::TestHelpers::TestLineFormatter.new("audit"),
      on_failure: nil
    )
      Julewire.configure do |config|
        config.on_failure = on_failure if on_failure
        config.destinations.use(
          :default,
          formatter: Julewire::Core::TestHelpers::TestLineFormatter.new("default"),
          output: default_output
        )
        config.destinations.use(
          :audit,
          formatter: formatter,
          output: audit_output,
          processors: processors
        )
      end
    end
  end
end
