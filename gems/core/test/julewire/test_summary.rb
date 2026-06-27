# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestSummary < Minitest::Test
    cover Julewire::Core::Fields::SummaryProxy
    cover Julewire::Core::Execution::SummaryState
    cover Julewire::Core::Execution::MeasurementHandle
    cover "Julewire::Core::FacadeMethods#measure"
    cover "Julewire::Core::FacadeMethods#measure_start"
    cover "Julewire::Core::FacadeMethods#summary"
    cover "Julewire::Core::Execution::Scope#measure_summary"
    cover "Julewire::Core::Execution::Scope#measure_summary_start"
    class AttributeHash < Hash; end

    class NestedHashProbe < Hash
      attr_reader :each_calls

      def initialize(fields)
        super()
        update(fields)
        @each_calls = 0
      end

      def each(...)
        @each_calls += 1
        super
      end
    end

    class MeasurementKey < String; end
    class WarningList < Array; end

    def test_summary_active_reflects_current_execution_scope
      refute_predicate Julewire.summary, :active?

      with_julewire_job do
        assert_predicate Julewire.summary, :active?
      end

      refute_predicate Julewire.summary, :active?
    end

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

    def test_owned_summary_attribute_merge_preserves_nested_hashes
      scope = build_execution_scope(type: :unit)

      scope.add_summary_attributes({ payload: { existing: true } }, owned: true)
      scope.add_summary_attributes({ payload: { added: true } }, owned: true)

      assert_equal(
        { existing: true, added: true },
        scope.summary_record_input.dig(:attributes, :payload)
      )
    end

    def test_append_treats_owned_array_subclasses_as_arrays
      scope = nil
      warnings = WarningList["first"]

      with_julewire_job do
        Julewire::Core::ContextStore.current.current_scope.add_summary({ warnings: warnings }, owned: true)
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

    def test_increment_appends_non_numeric_by_to_existing_numeric_value
      scope = nil

      with_julewire_job do
        Julewire.summary.add(count: 1)
        Julewire.summary.increment(:count, by: "two")
        scope = Julewire.current_execution
      end

      assert_equal({ count: [1, "two"] }, scope.summary_hash)
    end

    def test_increment_copies_new_hash_values
      scope = nil
      metadata = { "code" => "original" }

      with_julewire_job do
        Julewire.summary.increment(:warnings, by: metadata)
        metadata["code"] = "changed"
        scope = Julewire.current_execution
      end

      assert_equal({ warnings: { "code" => "original" } }, scope.summary_hash)
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

    def test_scope_non_owned_summary_fields_are_copied
      scope = nil
      payload = { "status" => "original" }

      with_julewire_job do
        scope = Julewire::Core::ContextStore.current.current_scope
        scope.add_summary({ "result" => payload }, owned: false)
        payload["status"] = "changed"
      end

      assert_equal({ result: { status: "original" } }, scope.summary_hash)
    end

    def test_scope_summary_fields_default_to_unowned_user_input
      key = Julewire::Core::Serialization::Serializer::TRUNCATION_METADATA_KEY
      metadata = Julewire::Core::Serialization::Serializer.truncation_metadata(["summary"])

      with_julewire_job do
        scope = Julewire::Core::ContextStore.current.current_scope

        error = assert_raises(ArgumentError) { scope.add_summary({ key => metadata }) }

        assert_equal "_julewire_truncation is reserved for Julewire truncation metadata", error.message
      end
    end

    def test_scope_owned_summary_writers_do_not_copy_nested_owned_values
      {
        add_summary: :owned,
        add_summary_attributes: :web,
        add_summary_neutral: :worker
      }.each do |writer, field|
        nested = NestedHashProbe.new(value: 1)

        with_julewire_job do
          scope = Julewire::Core::ContextStore.current.current_scope
          scope.public_send(writer, { field => nested }, owned: true)

          assert_equal 0, nested.each_calls
        end
      end
    end

    def test_add_returns_summary_proxy_for_chaining
      with_julewire_job do
        assert_same Julewire.summary, Julewire.summary.add(status: 200)
      end
    end

    def test_mutating_summary_helpers_return_summary_proxy_for_chaining
      with_julewire_job do
        assert_same Julewire.summary, Julewire.summary.increment(:processed)
        assert_same Julewire.summary, Julewire.summary.append(:warnings, "low-stock")
        assert_same Julewire.summary, Julewire.summary.increment_attribute(:web, :queries_count)
      end
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

    def test_add_attributes_merges_positional_and_keyword_fields
      record = nil

      capture_julewire_records do |records|
        Julewire.with_execution(type: :request, id: "request-1") do
          assert_same Julewire.summary, Julewire.summary.add_attributes(
            { web: { controller: "HomeController" } },
            service: "checkout"
          )
        end
        record = records.fetch(0)
      end

      assert_equal "HomeController", record.dig(:attributes, :web, :controller)
      assert_equal "checkout", record.dig(:attributes, :service)
    end

    def test_summary_measurements_accumulate_existing_metric_values
      state = Julewire::Core::Execution::SummaryState.new(event: "summary", severity: :info, source: "test")
      measurement = state.measurement(:db)

      state.record_measurement(measurement, 1.25)
      state.record_measurement(measurement, 2.75)

      assert_equal 2, state.payload_hash.fetch(:db_count)
      assert_in_delta(4.0, state.metrics_hash.fetch(:db_duration_ms))
    end

    def test_summary_state_hash_readers_return_independent_copies
      state = Julewire::Core::Execution::SummaryState.new(event: "summary", severity: :info, source: "test")
      measurement = state.measurement(:db)

      state.add({ nested: { value: "original" } }, owned: false)
      state.record_measurement(measurement, 1.25)

      payload = state.payload_hash
      metrics = state.metrics_hash
      payload[:nested][:value] = "changed"
      metrics[:db_duration_ms] = 99.9

      assert_equal "original", state.payload_hash.dig(:nested, :value)
      assert_in_delta 1.25, state.metrics_hash.fetch(:db_duration_ms)
    end

    def test_summary_state_append_copies_appended_values
      state = Julewire::Core::Execution::SummaryState.new(event: "summary", severity: :info, source: "test")
      warning = { code: "original" }

      state.append(:warnings, warning)
      warning[:code] = "changed"

      assert_equal [{ code: "original" }], state.payload_hash.fetch(:warnings)
    end

    def test_summary_state_record_input_returns_defensive_copy_after_finalize
      state = Julewire::Core::Execution::SummaryState.new(event: "summary", severity: :info, source: "test")
      state.add({ nested: { value: "original" } }, owned: false)
      state.finalize_record_input(**summary_record_fields)

      input = state.record_input(**summary_record_fields)
      input.dig(:payload, :nested)[:value] = "changed"

      assert_equal "original", state.record_input(**summary_record_fields).dig(:payload, :nested, :value)
    end

    def test_summary_state_record_input_carries_success_severity_and_metrics
      state = Julewire::Core::Execution::SummaryState.new(event: "summary", severity: :debug, source: "test")
      state.record_duration(12.5)

      input = state.record_input(**summary_record_fields)

      assert_equal :debug, input.fetch(:severity)
      assert_equal({ duration_ms: 12.5 }, input.fetch(:metrics))
    end

    def test_summary_state_non_standard_exception_reflects_recorded_errors
      state = Julewire::Core::Execution::SummaryState.new(event: "summary", severity: :info, source: "test")

      refute_predicate state, :non_standard_exception?

      state.record_error(RuntimeError.new("boom"), severity: nil)

      refute_predicate state, :non_standard_exception?

      state.record_error(SystemStackError.new("stack"), severity: nil)

      assert_predicate state, :non_standard_exception?
    end

    def test_summary_state_reuses_owned_base_sections_without_summary_overlays
      state = Julewire::Core::Execution::SummaryState.new(event: "summary", severity: :info, source: "test")
      base_attributes = hash_that_must_not_be_traversed.new
      base_neutral = hash_that_must_not_be_traversed.new

      assert_same base_attributes, state.__send__(:attributes_hash, base_attributes)
      assert_same base_neutral, state.__send__(:neutral_hash, base_neutral)
    end

    def test_increment_attribute_normalizes_nested_string_paths_and_default_increment
      record = nil

      capture_julewire_records do |records|
        Julewire.with_execution(type: :request, id: "request-1") do
          Julewire.summary.increment_attribute("web", "queries_count")
          Julewire.summary.increment_attribute(:web, :queries_count, by: 2)
          Julewire.summary.increment_attribute(%w[web cache_count])
        end
        record = records.fetch(0)
      end

      assert_equal 3, record.dig(:attributes, :web, :queries_count)
      assert_equal 1, record.dig(:attributes, :web, :cache_count)
    end

    def test_increment_attribute_builds_deep_normalized_paths
      record = nil

      capture_julewire_records do |records|
        Julewire.with_execution(type: :request, id: "request-1") do
          Julewire.summary.increment_attribute("web", "db", "queries_count")
        end
        record = records.fetch(0)
      end

      assert_equal 1, record.dig(:attributes, :web, :db, :queries_count)
      assert_false record.dig(:attributes, :web).key?(:queries_count)
    end

    def test_increment_attribute_replaces_non_hash_intermediate
      record = nil

      capture_julewire_records do |records|
        Julewire.with_execution(type: :request, id: "request-1") do
          Julewire.summary.add_attributes(web: "legacy")
          Julewire.summary.increment_attribute(:web, :queries_count)
        end
        record = records.fetch(0)
      end

      assert_equal({ queries_count: 1 }, record.dig(:attributes, :web))
    end

    def test_increment_attribute_preserves_hash_like_intermediate
      record = nil
      web = AttributeHash.new
      web[:controller] = "HomeController"

      capture_julewire_records do |records|
        Julewire.with_execution(type: :request, id: "request-1") do
          Julewire::Core::ContextStore.current.current_scope.add_summary_attributes({ web: web }, owned: true)
          Julewire.summary.increment_attribute(:web, :queries_count)
        end
        record = records.fetch(0)
      end

      assert_equal "HomeController", record.dig(:attributes, :web, :controller)
      assert_equal 1, record.dig(:attributes, :web, :queries_count)
    end

    def summary_record_fields
      {
        attributes: {},
        carry: {},
        context: {},
        execution: {},
        labels: {},
        neutral: {},
        timestamp: Time.utc(2026, 1, 1)
      }
    end

    def test_scope_non_owned_summary_sections_are_copied
      [
        { writer: :add_summary_attributes, section: :attributes, field: "web", nested_key: "controller" },
        { writer: :add_summary_neutral, section: :neutral, field: "worker", nested_key: "node" }
      ].each do |entry|
        assert_non_owned_summary_section_is_copied(**entry)
      end
    end

    def test_summary_proxy_add_attributes_passes_coerced_fields_as_owned
      scope = SummaryScopeSpy.new
      proxy = Julewire::Core::Fields::SummaryProxy.new(SummaryStoreSpy.new(scope))
      fields = { "web" => { "controller" => "HomeController" } }

      assert_same proxy, proxy.add_attributes(fields, service: "checkout")
      fields.fetch("web")["controller"] = "ChangedController"

      assert_true scope.attributes_owned
      assert_equal "HomeController", scope.attributes_fields.dig(:web, :controller)
      assert_equal "checkout", scope.attributes_fields.fetch(:service)
    end

    def test_summary_proxy_add_passes_coerced_fields_as_owned
      scope = SummaryScopeSpy.new
      proxy = Julewire::Core::Fields::SummaryProxy.new(SummaryStoreSpy.new(scope))
      fields = { "result" => { "status" => "ok" } }

      assert_same proxy, proxy.add(fields, processed: 1)
      fields.fetch("result")["status"] = "changed"

      assert_true scope.payload_owned
      assert_equal "ok", scope.payload_fields.dig(:result, :status)
      assert_equal 1, scope.payload_fields.fetch(:processed)
    end

    private

    def assert_non_owned_summary_section_is_copied(writer:, section:, field:, nested_key:)
      record = nil
      nested = { nested_key => "original" }

      capture_julewire_records do |records|
        Julewire.with_execution(type: :request, id: "request-1") do
          scope = Julewire::Core::ContextStore.current.current_scope
          scope.public_send(writer, { field => nested })
          nested[nested_key] = "changed"
        end
        record = records.fetch(0)
      end

      assert_equal "original", record.dig(section, field.to_sym, nested_key.to_sym)
    end

    public

    def test_scope_summary_increment_defaults_to_one
      scope = nil

      with_julewire_job do
        scope = Julewire::Core::ContextStore.current.current_scope
        scope.increment_summary(:processed)
        scope.increment_summary(:processed, by: 2)
        scope.increment_summary_attribute(%i[web queries_count])
        scope.increment_summary_attribute(%i[web queries_count], by: 2)
      end

      assert_equal 3, scope.summary_hash.fetch(:processed)
      assert_equal 3, scope.owned_summary_record_input.dig(:attributes, :web, :queries_count)
    end

    def test_increment_attribute_preserves_falsey_existing_values
      record = nil

      capture_julewire_records do |records|
        Julewire.with_execution(type: :request, id: "request-1") do
          Julewire.summary.add_attributes(web: { false_count: false, nil_count: nil })
          Julewire.summary.increment_attribute(:web, :false_count, by: 2)
          Julewire.summary.increment_attribute(:web, :nil_count, by: 3)
        end
        record = records.fetch(0)
      end

      assert_equal [false, 2], record.dig(:attributes, :web, :false_count)
      assert_equal [nil, 3], record.dig(:attributes, :web, :nil_count)
    end

    def test_increment_attribute_requires_path
      error = assert_raises(ArgumentError) do
        with_julewire_job do
          Julewire.summary.increment_attribute([])
        end
      end

      assert_equal "attribute path is required", error.message
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

    def test_measurement_handle_finishes_once
      calls = Queue.new
      start = Queue.new
      handle = Julewire::Core::Execution::MeasurementHandle.new { calls << true }
      threads = Array.new(16) do
        safe_thread do
          start.pop
          handle.finish
        end
      end

      assert_false handle.finished?
      16.times { start << true }
      safe_thread_values(threads)

      assert_predicate handle, :finished?
      assert(safe_queue_pop(calls))
      assert_raises(ThreadError) { calls.pop(true) }
    end

    def test_measure_records_deterministic_millisecond_durations
      scope = build_execution_scope(type: :job)
      times = [10.0, 10.1234567, 20.0, 20.9876543]
      scope.define_singleton_method(:monotonic_time) { times.shift }

      scope.measure_summary(:db) { :ok }
      scope.measure_summary_start(:cache).finish

      assert_equal 1, scope.summary_hash.fetch(:db_count)
      assert_in_delta(123.457, scope.metrics_hash.fetch(:db_duration_ms))
      assert_equal 1, scope.summary_hash.fetch(:cache_count)
      assert_in_delta(987.654, scope.metrics_hash.fetch(:cache_duration_ms))
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

    def test_summary_measure_requires_block
      with_julewire_job do
        error = assert_raises(ArgumentError) do
          Julewire.summary.measure(:db)
        end

        assert_equal "block required", error.message
      end
    end

    def test_measure_validates_key_before_running_block
      ran = false

      with_julewire_job do
        error = assert_raises(ArgumentError) do
          Julewire.measure("") { ran = true }
        end

        assert_equal "measurement key is required", error.message
      end

      assert_false ran
    end

    def test_measure_accepts_string_subclass_keys
      scope = nil

      with_julewire_job do
        Julewire.measure(MeasurementKey.new("db")) { :ok }
        scope = Julewire.current_execution
      end

      assert_equal 1, scope.summary_hash.fetch(:db_count)
      assert_operator scope.metrics_hash.fetch(:db_duration_ms), :>=, 0
    end

    def test_measure_rejects_non_string_symbol_keys_before_running_block
      ran = false

      with_julewire_job do
        error = assert_raises(ArgumentError) do
          Julewire.measure(Object.new) { ran = true }
        end

        assert_equal "measurement key must be a String or Symbol", error.message
      end

      assert_false ran
    end

    def hash_that_must_not_be_traversed
      Class.new(Hash) do
        def each
          raise "owned base section should not be traversed"
        end
      end
    end

    class SummaryStoreSpy
      def initialize(scope)
        @scope = scope
      end

      def current_scope = @scope
    end

    class SummaryScopeSpy
      attr_reader :attributes_fields, :attributes_owned, :payload_fields, :payload_owned

      def add_summary(fields, owned:)
        @payload_fields = fields
        @payload_owned = owned
      end

      def add_summary_attributes(fields, owned:)
        @attributes_fields = fields
        @attributes_owned = owned
      end
    end
  end
end
