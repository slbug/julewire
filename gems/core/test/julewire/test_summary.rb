# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestSummary < Minitest::Test
    cover Julewire::Core::Execution::MeasurementHandle
    cover Julewire::Core::Execution::SummaryState

    def test_increment_and_append_normalize_string_keys
      scope = nil

      with_julewire_job do
        Julewire.summary.increment(:processed)
        Julewire.summary.increment("processed", by: 2)
        Julewire.summary.append(:warnings, "sym")
        Julewire.summary.append("warnings", "string")
        scope = Julewire.current_execution
      end

      assert_equal({ processed: 3, warnings: %w[sym string] }, scope.summary_hash)
    end

    def test_append_converts_existing_scalar_to_array
      scope = nil

      with_julewire_job do
        Julewire.summary.add(warnings: "first")
        Julewire.summary.append("warnings", "second")
        scope = Julewire.current_execution
      end

      assert_equal({ warnings: %w[first second] }, scope.summary_hash)
    end

    def test_increment_converts_existing_nonnumeric_value_to_array
      scope = nil

      with_julewire_job do
        Julewire.summary.add(count: "one")
        Julewire.summary.increment(:count, by: 2)
        scope = Julewire.current_execution
      end

      assert_equal({ count: ["one", 2] }, scope.summary_hash)
    end

    def test_increment_preserves_falsey_existing_values
      scope = nil

      with_julewire_job do
        Julewire.summary.add(count: false)
        Julewire.summary.increment(:count, by: 2)
        scope = Julewire.current_execution
      end

      assert_equal({ count: [false, 2] }, scope.summary_hash)
    end

    def test_increment_preserves_nil_existing_values
      scope = nil

      with_julewire_job do
        Julewire.summary.add(count: nil)
        Julewire.summary.increment(:count, by: 2)
        scope = Julewire.current_execution
      end

      assert_equal({ count: [nil, 2] }, scope.summary_hash)
    end

    def test_append_preserves_nil_existing_values
      scope = nil

      with_julewire_job do
        Julewire.summary.add(warnings: nil)
        Julewire.summary.append(:warnings, "second")
        scope = Julewire.current_execution
      end

      assert_equal({ warnings: [nil, "second"] }, scope.summary_hash)
    end

    def test_append_preserves_existing_hash_as_single_array_item
      scope = nil

      with_julewire_job do
        Julewire.summary.add(warnings: { code: "first" })
        Julewire.summary.append(:warnings, { code: "second" })
        scope = Julewire.current_execution
      end

      assert_equal({ warnings: [{ code: "first" }, { code: "second" }] }, scope.summary_hash)
    end

    def test_add_wraps_non_hash_values_without_raising
      scope = nil

      with_julewire_job do
        Julewire.summary.add("summary-value", processed: 1)
        scope = Julewire.current_execution
      end

      assert_equal({ value: "summary-value", processed: 1 }, scope.summary_hash)
    end

    def test_add_preserves_top_level_overwrite_semantics
      scope = nil

      with_julewire_job do
        Julewire.summary.add(result: { previous: true })
        Julewire.summary.add("result" => { current: true })
        scope = Julewire.current_execution
      end

      assert_equal({ result: { current: true } }, scope.summary_hash)
    end

    def test_add_attributes_and_increment_attribute_feed_summary_attributes
      record = nil

      capture_julewire_records do |records|
        Julewire.with_execution(type: :request, id: "request-1") do
          Julewire.summary.add_attributes(web: { controller: "HomeController" })
          Julewire.summary.increment_attribute(:web, :queries_count)
        end
        record = records.fetch(0)
      end

      assert_empty record.fetch(:payload)
      assert_equal "HomeController", record.dig(:attributes, :web, :controller)
      assert_equal 1, record.dig(:attributes, :web, :queries_count)
    end

    def test_measure_records_count_and_duration
      scope = nil

      result = with_julewire_job do
        measured = Julewire.measure(:db) { "ok" }
        Julewire.summary.measure("db") { :again }
        scope = Julewire.current_execution
        measured
      end

      assert_equal "ok", result
      assert_equal 2, scope.summary_hash.fetch(:db_count)
      assert_operator scope.metrics_hash.fetch(:db_duration_ms), :>=, 0
    end

    def test_measure_start_records_when_handle_finishes
      scope = nil

      with_julewire_job do
        handle = Julewire.measure_start(:cache)

        refute_predicate handle, :finished?

        handle.finish
        handle.finish

        assert_predicate handle, :finished?

        scope = Julewire.current_execution
      end

      assert_equal 1, scope.summary_hash.fetch(:cache_count)
      assert_operator scope.metrics_hash.fetch(:cache_duration_ms), :>=, 0
    end

    def test_measure_start_requires_current_execution_scope
      error = assert_raises(Julewire::Core::Execution::NoCurrentError) do
        Julewire.measure_start(:db)
      end

      assert_match "current execution", error.message
    end

    def test_measure_records_failed_blocks_and_reraises
      scope = nil

      error = assert_raises(RuntimeError) do
        with_julewire_job do
          Julewire.measure(:external_call) do
            scope = Julewire.current_execution
            raise "upstream failed"
          end
        end
      end

      assert_equal "upstream failed", error.message
      assert_equal 1, scope.summary_hash.fetch(:external_call_count)
      assert_operator scope.metrics_hash.fetch(:external_call_duration_ms), :>=, 0
    end

    def test_measure_requires_current_execution_scope
      error = assert_raises(Julewire::Core::Execution::NoCurrentError) do
        Julewire.measure(:db) { :unused }
      end

      assert_match "current execution", error.message
    end

    def test_measure_validates_key_before_running_block
      ran = false

      with_julewire_job do
        error = assert_raises(ArgumentError) do
          Julewire.measure("") { ran = true }
        end

        assert_equal "measurement key is required", error.message
      end

      refute ran
    end
  end
end
