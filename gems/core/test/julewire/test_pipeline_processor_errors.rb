# frozen_string_literal: true

require "test_helper"
require "json"
require "stringio"

module Julewire
  class TestPipelineProcessorErrors < Minitest::Test
    class ToHRaisingRecord < Julewire::Core::Records::Record
      def to_h
        raise "to_h should not be called"
      end
    end

    def test_pipeline_ignores_ordinary_processor_results
      output = StringIO.new
      pipeline = build_pipeline(
        labels: { service: "core" },
        processors: [->(_record) { "not a record" }],
        output: output
      )

      pipeline.emit(message: "hello")

      record = JSON.parse(output.string)

      assert_equal "log", record["event"]
      assert_equal "hello", record["message"]
      assert_equal "core", record.dig("labels", "service")
      assert_equal 0, pipeline.health.dig(:counts, :processor_error)
    end

    def test_processor_nil_result_is_noop
      filter = Object.new
      filter.define_singleton_method(:call) { |_record| nil }
      output = StringIO.new
      pipeline = build_pipeline(processors: [filter], output: output)

      pipeline.emit(message: "hello")

      record = JSON.parse(output.string)

      assert_equal "log", record.fetch("event")
      assert_equal "hello", record.fetch("message")
      assert_equal 0, pipeline.health.dig(:counts, :processor_error)
    end

    def test_processor_failure_callback_failure_is_visible_in_pipeline_health
      Julewire.configure do |config|
        configure_destination(config, output: StringIO.new)
        config.processors.use(->(_record) { raise "processor boom" })
        config.on_failure = ->(_error, _metadata) { raise "callback boom" }
      end

      Julewire.emit(message: "bad processor")

      health = Julewire.health.fetch(:pipeline)

      assert_equal 1, health.dig(:counts, :callback_error)
      assert_equal "RuntimeError", health.dig(:last_callback_failure, :class)
      assert_equal :processor, health.dig(:last_callback_failure, :phase)
    end

    def test_fail_closed_processor_error_bypasses_application_level_threshold
      output = StringIO.new

      Julewire.configure do |config|
        config.level = :fatal
        configure_destination(config, output: output)
        config.processors.use(->(_record) { raise "processor boom" })
      end

      Julewire.fatal(message: "application fatal")

      record = JSON.parse(output.string)

      assert_equal "julewire.processor_error", record.fetch("event")
      assert_equal "Julewire processor failed", record.fetch("message")
      assert_equal 1, Julewire.health.dig(:pipeline, :counts, :processor_error)
    end

    def test_pipeline_degraded_status_recovers_after_later_successful_emit
      output = StringIO.new
      failed = false

      Julewire.configure do |config|
        configure_destination(config, output: output)
        config.processors.use(
          lambda do |_record|
            next if failed

            failed = true
            raise "processor boom"
          end
        )
      end

      Julewire.emit(message: "first")

      assert_equal :degraded, Julewire.health.dig(:pipeline, :status)
      assert_equal :degraded, Julewire.health.fetch(:status)

      Julewire.emit(message: "second")
      health = Julewire.health

      assert_equal :ok, health.dig(:pipeline, :status)
      assert_equal :ok, health.fetch(:status)
      assert_equal 1, health.dig(:pipeline, :counts, :processor_error)
      assert_equal "RuntimeError", health.dig(:pipeline, :last_failure, :class)
    end

    def test_fail_open_processor_error_policy_keeps_current_draft
      output = StringIO.new

      configure_fail_open_processor_pipeline(output)
      Julewire.emit(message: "hello", payload: {})

      assert_fail_open_record(JSON.parse(output.string), Julewire.health.fetch(:pipeline))
    end

    def test_drop_processor_error_policy_suppresses_record
      output = StringIO.new

      Julewire.configure do |config|
        configure_destination(config, output: output)
        config.processors.use(->(_record) { raise "processor boom" }, on_error: :drop)
        config.processors.use(->(record) { record[:payload][:after_error] = true })
      end

      Julewire.emit(message: "hello", payload: {})

      health = Julewire.health.fetch(:pipeline)

      assert_empty output.string
      assert_equal 1, health.dig(:counts, :processor_error)
      assert_equal 1, health.dig(:counts, :processor_dropped)
    end

    def test_final_record_boundary_reports_non_raising_processor_corruption_as_emit_record_failure
      failures = Queue.new
      output = StringIO.new
      processor = lambda do |record|
        record.transform_record! do |data|
          data.dup.tap { it.delete(:event) }
        end
      end
      pipeline = build_pipeline(
        on_failure: ->(_error, metadata) { failures << metadata },
        output: output,
        processors: [processor]
      )

      pipeline.emit(event: "work.started", source: "app", labels: { service: "core" })

      failure_metadata = failures.pop

      assert_empty output.string
      assert_equal 0, pipeline.health.dig(:counts, :processor_error)
      assert_equal :emit_record, failure_metadata.fetch(:phase)
      refute failure_metadata.dig(:record_metadata, :event)
      assert_equal({ service: "core" }, failure_metadata.dig(:record_metadata, :labels))
    end

    def test_direct_section_mutation_is_allowed_on_processor_drafts
      output = StringIO.new
      input_context = { account: { id: "acct-1" } }
      processor = lambda do |record|
        record[:context][:account][:id] = "mutated"
        nil
      end
      pipeline = build_pipeline(output: output, processors: [processor])

      pipeline.emit(message: "hello", context: input_context)

      record = JSON.parse(output.string)

      assert_equal "log", record.fetch("event")
      assert_equal "mutated", record.dig("context", "account", "id")
      assert_equal "acct-1", input_context.dig(:account, :id)
    end

    def test_processor_top_level_assignment_keeps_sections_mutable_until_record_boundary
      output = StringIO.new
      processor = lambda do |record|
        record[:payload] = { nested: { value: 1 } }
        record[:payload][:nested][:value] = 2
        nil
      end
      pipeline = build_pipeline(output: output, processors: [processor])

      pipeline.emit(message: "hello")

      record = JSON.parse(output.string)

      assert_equal 2, record.dig("payload", "nested", "value")
      assert_equal 0, pipeline.health.dig(:counts, :processor_error)
    end

    def test_emit_record_fast_path_does_not_thaw_prebuilt_records_without_processors_or_labels
      output = StringIO.new
      pipeline = build_pipeline(output: output)
      base = Julewire::Core::Records::Draft.build(
        { event: "prebuilt.fast_path", payload: { value: 1 } },
        context: {},
        scope: nil
      ).to_record
      record = ToHRaisingRecord.new(base.serializable_data)

      pipeline.emit_record(record)

      emitted = JSON.parse(output.string)

      assert_equal "prebuilt.fast_path", emitted.fetch("event")
      assert_equal 1, pipeline.health.dig(:counts, :entered)
    end

    def test_emit_record_processor_receives_mutable_draft
      output = StringIO.new
      processor = lambda do |record|
        record[:payload][:nested][:value] = 2
        nil
      end
      pipeline = build_pipeline(output: output, processors: [processor])
      record = Julewire::Core::Records::Draft.build(
        { event: "prebuilt.processed", payload: { nested: { value: 1 } } },
        context: {},
        scope: nil
      ).to_record

      pipeline.emit_record(record)

      emitted = JSON.parse(output.string)

      assert_equal 2, emitted.dig("payload", "nested", "value")
      assert_equal 1, record.to_h.dig(:payload, :nested, :value)
      assert_equal 0, pipeline.health.dig(:counts, :processor_error)
    end

    private

    def configure_fail_open_processor_pipeline(output)
      Julewire.configure do |config|
        configure_destination(config, output: output)
        config.processors.use(lambda do |record|
          record[:payload][:before_error] = true
          raise "processor boom"
        end, on_error: :fail_open)
        config.processors.use(->(record) { record[:payload][:after_error] = true })
      end
    end

    def assert_fail_open_record(record, health)
      assert_equal "log", record.fetch("event")
      assert_equal "hello", record.fetch("message")
      assert record.dig("payload", "before_error")
      assert record.dig("payload", "after_error")
      assert_equal 1, health.dig(:counts, :processor_error)
      assert_equal 0, health.dig(:counts, :processor_dropped)
    end
  end
end
