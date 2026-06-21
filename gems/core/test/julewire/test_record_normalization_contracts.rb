# frozen_string_literal: true

require "test_helper"
require "json"
require "stringio"

module Julewire
  class TestRecordNormalizationContracts < Minitest::Test
    cover Julewire::Core::Records::Record
    cover Julewire::Core::Serialization::ValueCopy

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
      refute record.dig("payload", "processed")
      assert_equal 0, pipeline.health.dig(:counts, :processor_error)
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
      capture_io do
        record = Julewire::Core::Records::Draft.build({ severity: :bogus }, context: {}, scope: nil)
      end

      assert_equal :info, record.fetch(:severity)
    end

    def test_record_draft_defaults_non_stringable_explicit_severity_to_info
      record = nil
      capture_io do
        record = Julewire::Core::Records::Draft.build({ severity: Object.new }, context: {}, scope: nil)
      end

      assert_equal :info, record.fetch(:severity)
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
      assert first.eql?(second)
      refute_equal first, different
      refute first.eql?(different)
      refute_equal first, record_shaped_object
      refute first.eql?(record_shaped_object)
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
        normalized_record(payload: { value: "before" }),
        freeze_sections: false
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
