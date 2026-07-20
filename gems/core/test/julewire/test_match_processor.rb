# frozen_string_literal: true

require "test_helper"
require "json"
require "stringio"

module Julewire
  class TestMatchProcessor < Minitest::Test
    cover "Julewire::Core::Processing.build"
    cover "Julewire::Core::Processing.factory_for"
    cover "Julewire::Core::Processing::InvalidResultFailure*"
    cover "Julewire::Core::Processing.normalize_kind"
    cover "Julewire::Core::Processing.register"
    cover Julewire::Core::Processing::Pipeline
    cover "Julewire::Core::Processing::ProcessorChain*"
    cover "Julewire::Core::Processing::Pipeline#after_fork!"
    cover "Julewire::Core::Processing::Pipeline#build_draft"
    cover "Julewire::Core::Processing::Pipeline#build_draft_from"
    cover "Julewire::Core::Processing::Pipeline#build_threshold"
    cover "Julewire::Core::Processing::Pipeline#close"
    cover "Julewire::Core::Processing::Pipeline#destination_defaults"
    cover "Julewire::Core::Processing::Pipeline#emit"
    cover "Julewire::Core::Processing::Pipeline#emit_fast_record"
    cover "Julewire::Core::Processing::Pipeline#emit_input_with_guard"
    cover "Julewire::Core::Processing::Pipeline#emit_internal_error_record"
    cover "Julewire::Core::Processing::Pipeline#emit_prepared_draft"
    cover "Julewire::Core::Processing::Pipeline#emit_processed_draft"
    cover "Julewire::Core::Processing::Pipeline#emit_with_level_check"
    cover "Julewire::Core::Processing::Pipeline#raw_input_blocked?"
    cover Julewire::Core::Processing::ProcessorRegistry
    cover "Julewire::Core::Records::Draft::Builder*"
    cover Julewire::Core::Processing::ProcessorWrapper
    cover Julewire::Match
    def test_match_processor_applies_only_matching_rules
      records = []

      output = StringIO.new
      pipeline = build_pipeline(output: output, processors: [slow_sql_match_processor])
      pipeline.emit(event: "sql.query", payload: { duration_ms: 125 })
      records << JSON.parse(output.string)

      output = StringIO.new
      pipeline = build_pipeline(output: output, processors: [slow_sql_match_processor])
      pipeline.emit(event: "sql.query", payload: { duration_ms: 3 })
      records << JSON.parse(output.string)

      assert_true records.fetch(0).dig("labels", "slow_sql")
      assert_nil records.fetch(1).dig("labels", "slow_sql")
    end

    def test_match_processor_supports_class_patterns
      output = StringIO.new
      processor = Julewire::Match.new do
        on(payload: { attempts: Integer }) do |draft|
          draft[:labels][:counted] = true
        end
      end
      pipeline = build_pipeline(output: output, processors: [processor])

      pipeline.emit(payload: { attempts: 2 })

      record = JSON.parse(output.string)

      assert_true record.dig("labels", "counted")
    end

    def test_match_processor_rejects_invalid_or_empty_conditions
      non_hash = assert_raises(ArgumentError) do
        Julewire::Match.new { on(:event) { nil } }
      end
      empty = assert_raises(ArgumentError) do
        Julewire::Match.new { on { nil } }
      end

      assert_equal "match conditions must be a Hash", non_hash.message
      assert_equal "match conditions are required", empty.message
    end

    def test_match_processor_duplicates_conditions_and_merges_keywords
      output = StringIO.new
      conditions = { event: "sql.query" }
      processor = Julewire::Match.new do
        on(conditions, severity: :info) do |draft|
          draft[:labels][:matched] = true
        end
      end
      conditions[:event] = "changed"
      pipeline = build_pipeline(output: output, processors: [processor])

      pipeline.emit(event: "sql.query", severity: :debug)
      pipeline.emit(event: "sql.query", severity: :info)

      records = output.string.lines.map { JSON.parse(it) }

      assert_nil records.fetch(0).dig("labels", "matched")
      assert_true records.fetch(1).dig("labels", "matched")
    end

    def test_match_processor_can_drop_records
      output = StringIO.new
      processor = Julewire::Match.new do
        on(severity: :debug) { :drop }
      end
      pipeline = build_pipeline(output: output, processors: [processor])

      pipeline.emit(severity: :debug, message: "noise")

      assert_empty output.string
      assert_equal 1, pipeline.health.dig(:counts, :processor_dropped)
    end

    def test_match_condition_errors_use_pipeline_processor_failure_path
      output = StringIO.new
      processor = Julewire::Match.new do
        on(payload: ->(_value) { raise "condition failed" }) do |draft|
          draft[:labels][:matched] = true
        end
      end
      pipeline = build_pipeline(output: output, processors: [processor])

      pipeline.emit(payload: {})

      record = JSON.parse(output.string)

      assert_equal "julewire.processor_error", record.fetch("event")
      assert_equal 1, pipeline.health.dig(:counts, :processor_error)
      refute_includes output.string, "condition failed"
      assert_nil record.dig("labels", "matched")
    end

    private

    def slow_sql_match_processor
      Julewire::Match.new do
        on(event: /^sql\./, payload: { duration_ms: 100.. }) do |draft|
          draft[:labels][:slow_sql] = true
        end
      end
    end
  end
end
