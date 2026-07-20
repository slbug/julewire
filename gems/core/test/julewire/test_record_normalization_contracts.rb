# frozen_string_literal: true

require "test_helper"
require "json"
require "stringio"

module Julewire
  class TestRecordNormalizationContracts < Minitest::Test
    cover "Julewire::Core::Diagnostics::InvalidSeverityReporter.call"
    cover "Julewire::Core::Diagnostics::InvalidSeverityReporter.warning_only"
    cover Julewire::Core::Records::Record
    cover Julewire::Core::Records::Draft
    cover "Julewire::Core::Records::Draft::Builder*"
    cover "Julewire::Core::Records::Deconstruct#deconstruct_keys"

    class CapturingFormatter
      attr_reader :record

      def call(record)
        @record = record
        {}
      end
    end

    def test_pipeline_ignores_processor_hash_results
      output = StringIO.new
      processor = lambda do |record|
        record.to_h.merge(
          "labels" => { "tenant" => "tenant-1" },
          "payload" => { "processed" => true },
          "severity" => "warn"
        )
      end
      pipeline = build_pipeline(output: output, processors: [processor])

      pipeline.emit(payload: {})

      record = JSON.parse(output.string)

      refute_equal "julewire.processor_error", record.fetch("event")
      assert_nil record.dig("payload", "processed")
      assert_equal 0, pipeline.health.dig(:counts, :processor_error)
      assert_equal 1, pipeline.health.dig(:counts, :processor_invalid)
      assert_equal :processor_result, pipeline.health.dig(:last_failure, :phase)
      assert_equal "Hash", pipeline.health.dig(:last_failure, :result_class)
    end

    def test_emit_defaults_bad_record_severity_to_info
      output = StringIO.new
      Julewire.configure do |config|
        configure_destination(config, output: output)
      end

      capture_io do
        Julewire.emit(severity: Object.new, message: "hello")
      end

      record = JSON.parse(output.string)

      assert_equal "log", record["event"]
      assert_equal "info", record["severity"]
      assert_equal "hello", record["message"]
    end

    def test_record_draft_defaults_invalid_explicit_severity_to_info
      record = nil
      _stdout, stderr = capture_io do
        record = Julewire::Core::Records::Draft.build({ severity: :bogus }, context: {}, scope: nil)
      end

      assert_equal :info, record.fetch(:severity)
      assert_includes stderr, "unsupported record severity Symbol"
    end

    def test_record_normalizes_nil_input_and_non_exception_errors
      nil_record = build_record(nil, context: {}, scope: nil)
      string_error_record = build_record({ error: "boom" }, context: {}, scope: nil)
      nil_backtrace_record = build_record({ error: RuntimeError.new("boom") }, context: {}, scope: nil)

      assert_equal "log", nil_record[:event]
      assert_nil nil_record[:message]
      assert_equal({ message: "boom" }, string_error_record[:error])
      assert_nil nil_backtrace_record.dig(:error, :backtrace)
    end

    def test_record_draft_defaults_non_stringable_explicit_severity_to_info
      record = nil
      _stdout, stderr = capture_io do
        record = Julewire::Core::Records::Draft.build({ severity: Object.new }, context: {}, scope: nil)
      end

      assert_equal :info, record.fetch(:severity)
      assert_includes stderr, "unsupported record severity Object"
    end

    def test_record_from_normalized_hash_rejects_non_hash_values
      assert_record_from_normalized_hash_rejects("not a record", "record must be a normalized Hash")
    end

    def test_record_from_normalized_hash_rejects_string_keys
      assert_record_from_normalized_hash_rejects(
        normalized_record.merge("payload" => {}),
        "record must not use string keys"
      )
    end

    def test_record_from_normalized_hash_rejects_non_symbol_keys
      assert_record_from_normalized_hash_rejects(
        normalized_record(payload: { Object.new => true }),
        "record keys must be Symbols"
      )
    end

    def test_raw_record_input_rejects_object_keys
      error = assert_raises(TypeError) do
        Julewire::Core::Records::Draft.build({ Object.new => true }, context: {}, scope: nil)
      end

      assert_equal "field keys must be String or Symbol", error.message
    end

    def test_raw_record_input_rejects_object_keys_before_traversing_values
      value = Object.new
      def value.is_a?(klass)
        raise "value should not be traversed before key validation" if [Hash, Array].include?(klass)

        super
      end

      error = assert_raises(TypeError) do
        Julewire::Core::Fields::FieldSet.deep_symbolize_keys(Object.new => value)
      end

      assert_equal "field keys must be String or Symbol", error.message
    end

    def test_record_from_normalized_hash_rejects_unknown_top_level_keys
      assert_record_from_normalized_hash_rejects(
        normalized_record.merge(tags: {}),
        "record has unknown top-level keys: tags"
      )
    end

    def test_record_from_normalized_hash_rejects_missing_execution
      input = normalized_record
      input.delete(:execution)

      assert_record_from_normalized_hash_rejects(input, "record must be complete (missing: execution)")
    end

    def test_record_from_normalized_hash_rejects_invalid_normalized_kind
      error = assert_record_from_normalized_hash_error(kind: :bad)
      assert_equal "record kind must be :point or :summary", error.message
    end

    def test_record_from_normalized_hash_rejects_invalid_normalized_severity
      error = assert_record_from_normalized_hash_error(severity: :bogus)
      assert_equal "record severity must be one of: debug, info, warn, error, fatal, unknown", error.message
    end

    def test_record_value_semantics_work_in_hashes_and_sets
      timestamp = Time.utc(2026, 1, 1)
      first = Julewire::Core::Records::Record.from_normalized_hash(normalized_record(timestamp: timestamp,
                                                                                     payload: { id: 1 }))
      second = Julewire::Core::Records::Record.from_normalized_hash(normalized_record(timestamp: timestamp,
                                                                                      payload: { id: 1 }))
      different = Julewire::Core::Records::Record.from_normalized_hash(normalized_record(timestamp: timestamp,
                                                                                         payload: { id: 2 }))
      record_shaped_object = Struct.new(:serializable_data).new(first.serializable_data)

      assert_equal first, second
      assert_eql first, second
      refute_equal first, different
      refute_eql first, different
      refute_equal first, record_shaped_object
      refute_eql first, record_shaped_object
      assert_equal first.hash, second.hash
      assert_equal "stored", { first => "stored" }.fetch(second)
      refute_equal first.to_h, first
    end

    def test_record_index_reads_normalized_data_without_copying
      record = Julewire::Core::Records::Record.from_normalized_hash(normalized_record(payload: { id: 1 }))

      assert_equal :info, record[:severity]
      assert_equal({ id: 1 }, record[:payload])
      assert_nil record[:missing]
    end

    def test_record_round_trips_through_draft_and_normalized_hash
      inputs = [
        normalized_record(payload: { value: "one" }, attributes: { service: { name: "api" } }),
        normalized_record(kind: :summary, event: "job.completed", metrics: { duration_ms: 12.3 },
                          execution: { type: "job", id: "job-1" }, payload: { total: 3 }),
        normalized_record(error: { class: "RuntimeError", handled: false })
      ]

      inputs.map { Julewire::Core::Records::Record.from_normalized_hash(it) }.each do |record|
        assert_equal record, Julewire::Core::Records::Draft.from_record(record).to_record
        assert_equal record, Julewire::Core::Records::Record.from_normalized_hash(record.to_h)
      end
    end

    def test_record_and_draft_deconstruct_keys_return_defensive_copies
      record = Julewire::Core::Records::Record.from_normalized_hash(normalized_record(payload: { ids: ["one"] }))
      draft = Julewire::Core::Records::Draft.from_normalized_hash(normalized_record(payload: { ids: ["one"] }))

      record_match = case record
                     in { payload: { ids: ids } }
                       ids
                     end
      draft_match = case draft
                    in { payload: { ids: ids } }
                      ids
                    end

      record_match << "two"
      draft_match << "two"

      assert_equal ["one"], record.dig(:payload, :ids)
      assert_equal ["one"], draft.dig(:payload, :ids)
    end

    def test_record_and_draft_deconstruct_keys_select_requested_existing_keys
      record = Julewire::Core::Records::Record.from_normalized_hash(normalized_record(payload: { ids: ["one"] }))
      draft = Julewire::Core::Records::Draft.from_normalized_hash(normalized_record(payload: { ids: ["one"] }))

      record_match = record.deconstruct_keys(%i[payload missing])
      draft_match = draft.deconstruct_keys(%i[payload missing])

      assert_equal({ payload: { ids: ["one"] } }, record_match)
      assert_equal({ payload: { ids: ["one"] } }, draft_match)
      refute_includes record_match, :missing
      refute_includes draft_match, :missing

      record_match.fetch(:payload).fetch(:ids) << "two"
      draft_match.fetch(:payload).fetch(:ids) << "two"

      assert_equal ["one"], record.dig(:payload, :ids)
      assert_equal ["one"], draft.dig(:payload, :ids)
    end

    def test_record_and_draft_deconstruct_keys_without_requested_keys_return_full_defensive_hash
      record = Julewire::Core::Records::Record.from_normalized_hash(normalized_record(payload: { ids: ["one"] }))
      draft = Julewire::Core::Records::Draft.from_normalized_hash(normalized_record(payload: { ids: ["one"] }))

      record_hash = record.deconstruct_keys(nil)
      draft_hash = draft.deconstruct_keys(nil)

      assert_equal record.to_h, record_hash
      assert_equal draft.to_h, draft_hash

      record_hash.fetch(:payload).fetch(:ids) << "two"
      draft_hash.fetch(:payload).fetch(:ids) << "two"

      assert_equal %w[one two], record_hash.dig(:payload, :ids)
      assert_equal %w[one two], draft_hash.dig(:payload, :ids)
      assert_equal ["one"], record.dig(:payload, :ids)
      assert_equal ["one"], draft.dig(:payload, :ids)
    end

    def test_record_from_normalized_hash_rejects_scalar_sections
      assert_record_from_normalized_hash_rejects(
        normalized_record(payload: "not normalized"),
        "record payload must be a Hash"
      )
    end

    def test_record_from_normalized_hash_rejects_missing_required_keys
      input = normalized_record
      input.delete(:metrics)
      input.delete(:payload)

      assert_record_from_normalized_hash_rejects(input, "record must be complete (missing: payload, metrics)")
    end

    def test_record_from_normalized_hash_rejects_invalid_error_section
      assert_record_from_normalized_hash_rejects(
        normalized_record(error: "RuntimeError"),
        "record error must be nil or a Hash"
      )
    end

    def test_record_draft_transform_is_validated_only_at_record_boundary
      draft = Julewire::Core::Records::Draft.from_normalized_hash(normalized_record)

      draft.transform_record! { normalized_record(severity: "warn") }
      error = assert_raises(TypeError) { draft.to_record }

      assert_match "record severity must be one of", error.message
      assert_equal "warn", draft.fetch(:severity)

      draft[:severity] = :warn

      assert_equal :warn, draft.to_record.fetch(:severity)
    end

    def test_record_draft_update_freezes_when_finalized
      draft = Julewire::Core::Records::Draft.from_normalized_hash(
        normalized_record(payload: { value: "before" })
      )

      draft[:labels] = { tenant: "tenant-1" }
      updated = draft.to_record

      assert_equal({ value: "before" }, updated.fetch(:payload))
      assert_equal({ tenant: "tenant-1" }, updated.fetch(:labels))
      assert_predicate updated.fetch(:labels), :frozen?
    end

    def test_record_from_normalized_hash_marks_circular_container_references
      hash = {}
      hash[:self] = hash
      array = []
      array << array

      record = Julewire::Core::Records::Record.from_normalized_hash(
        normalized_record(payload: { hash: hash, array: array })
      )

      assert_equal Julewire::Core::CIRCULAR_REFERENCE, record.dig(:payload, :hash, :self)
      assert_equal [Julewire::Core::CIRCULAR_REFERENCE], record.dig(:payload, :array)
    end

    private

    def assert_record_from_normalized_hash_error(**overrides)
      assert_raises(TypeError) do
        Julewire::Core::Records::Record.from_normalized_hash(normalized_record(**overrides))
      end
    end

    def assert_record_from_normalized_hash_rejects(input, message)
      error = assert_raises(TypeError) do
        Julewire::Core::Records::Record.from_normalized_hash(input)
      end

      assert_equal message, error.message
    end
  end
end
