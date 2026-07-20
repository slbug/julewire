# frozen_string_literal: true

require "test_helper"
require "prism"

module Julewire
  class TestRecordPublicSurface < Minitest::Test
    cover Julewire::Core::Records::Record
    cover Julewire::Core::Records::Draft
    cover "Julewire::Core::Records::Draft::Builder*"
    cover Julewire::Core::Records::PublicProjection

    def test_record_public_readers_delegate_to_normalized_data
      input = normalized_record(message: "hello", payload: { id: 1 }, metrics: { duration_ms: 3 })
      record = Julewire::Core::Records::Record.from_normalized_hash(input)

      assert_true record.key?(:payload)
      assert_false record.key?(:missing)
      assert_equal "hello", record.message
      assert_equal :info, record.fetch(:severity)
      assert_equal 1, record.dig(:payload, :id)
      assert_equal(input.keys, record.map { |key, _value| key })
      assert_match(/\A#<Julewire::Core::Records::Record /, record.inspect)
      assert_includes record.inspect, "payload"
    end

    def test_record_shape_docs_match_bag_taxonomy
      docs = File.read(File.expand_path("../../docs/records-and-data-policy.md", __dir__))
      body = docs.match(/canonical symbol-key shape is:\n\n```ruby\n(?<body>.*?)\n```/m)[:body]
      documented_keys = documented_record_keys(body)

      assert_equal Julewire::Core::Fields::Bags.required_record_keys, documented_keys
    end

    def test_record_to_h_returns_defensive_copy
      input = normalized_record(payload: { ids: ["one"] })
      record = Julewire::Core::Records::Record.from_normalized_hash(input)

      copy = record.to_h
      copy.fetch(:payload).fetch(:ids) << "two"

      assert_equal ["one"], record.dig(:payload, :ids)
      refute_same copy.fetch(:payload), record.serializable_data.fetch(:payload)
    end

    def test_record_normalization_returns_frozen_internal_data
      input = normalized_record(payload: { ids: ["one"] })
      record = Julewire::Core::Records::Record.from_normalized_hash(input)

      assert_predicate record, :frozen?
      assert_predicate record.serializable_data, :frozen?
      assert_predicate record.fetch(:payload), :frozen?
      assert_predicate record.dig(:payload, :ids), :frozen?
    end

    def test_record_validate_normalized_returns_records_only
      record = Julewire::Core::Records::Record.from_normalized_hash(normalized_record)

      assert_same record, Julewire::Core::Records::Record.validate_normalized!(record)

      error = assert_raises(TypeError) do
        Julewire::Core::Records::Record.validate_normalized!(record.to_h)
      end
      assert_equal "expected Julewire::Record", error.message
    end

    def test_record_validate_normalized_accepts_record_subclasses
      subclass = Class.new(Julewire::Core::Records::Record)
      record = subclass.new(normalized_record)

      assert_same record, Julewire::Core::Records::Record.validate_normalized!(record)
    end

    def test_record_validate_normalized_hash_returns_original_hash
      input = normalized_record

      assert_same input, Julewire::Core::Records::Record.validate_normalized_hash!(input)
    end

    def test_record_new_without_explicit_lineage_derives_from_execution
      record = Julewire::Core::Records::Record.new(
        normalized_record(execution: { type: "job", id: "child", depth: 2, root: { type: "request", id: "root" } })
      )

      assert_equal 2, record.lineage.depth
      assert_equal({ type: "request", id: "root" }, record.lineage.root_reference)
      assert_predicate record.lineage, :frozen?
    end

    def test_record_from_normalized_hash_preserves_explicit_lineage
      lineage = Julewire::Core::Execution::Lineage.new(
        reference: { type: "job", id: "child" },
        root_reference: { type: "request", id: "root" },
        parent_reference: { type: "job", id: "parent" },
        depth: 3,
        ancestors: [{ type: "request", id: "root" }]
      )

      record = Julewire::Core::Records::Record.from_normalized_hash(
        normalized_record(execution: { type: "job", id: "child", ancestors: [{ id: "stale" }] }),
        lineage: lineage
      )

      assert_same lineage, record.lineage
      assert_predicate lineage, :frozen?
      assert_false record.fetch(:execution).key?(:ancestors)
      assert_equal 3, record.lineage.depth
      assert_equal [{ type: "request", id: "root" }], record.lineage.ancestors
    end

    def test_record_from_normalized_hash_derives_lineage_before_cleaning_lazy_keys
      record = Julewire::Core::Records::Record.from_normalized_hash(
        normalized_record(
          execution: {
            type: "job",
            id: "child",
            ancestors: [{ type: "request", id: "root" }],
            ancestors_truncated: true
          }
        )
      )

      assert_equal [{ type: "request", id: "root" }], record.lineage.ancestors
      assert_predicate record.lineage, :truncated?
      assert_equal "job", record.dig(:execution, :type)
      assert_equal "child", record.dig(:execution, :id)
      assert_false record.fetch(:execution).key?(:ancestors)
      assert_false record.fetch(:execution).key?(:ancestors_truncated)
    end

    def test_record_from_normalized_hash_cleans_hash_subclass_lineage_keys
      input = Class.new(Hash).new.merge!(
        normalized_record(
          execution: { type: "job", id: "child", ancestors: [{ type: "request", id: "root" }] }
        )
      )

      record = Julewire::Core::Records::Record.from_normalized_hash(input)

      assert_equal [{ type: "request", id: "root" }], record.lineage.ancestors
      assert_false record.fetch(:execution).key?(:ancestors)
    end

    def test_draft_from_normalized_hash_rejects_non_hash_values
      error = assert_raises(TypeError) do
        Julewire::Core::Records::Draft.from_normalized_hash("not a record")
      end

      assert_equal "record must be a normalized Hash", error.message
    end

    def test_draft_from_normalized_hash_duplicates_input_and_derives_lineage_before_cleanup
      input = normalized_record(
        execution: {
          type: "job",
          id: "child",
          ancestors: [{ type: "request", id: "root" }],
          ancestors_truncated: true
        },
        payload: { ids: ["one"] }
      )

      draft = Julewire::Core::Records::Draft.from_normalized_hash(input)

      assert_true input.fetch(:execution).key?(:ancestors)
      assert_true input.fetch(:execution).key?(:ancestors_truncated)
      assert_false draft.fetch(:execution).key?(:ancestors)
      assert_false draft.fetch(:execution).key?(:ancestors_truncated)
      assert_equal [{ type: "request", id: "root" }], draft.lineage.ancestors
      assert_predicate draft.lineage, :truncated?
      refute_same input.fetch(:payload), draft.fetch(:payload)
      refute_predicate draft.fetch(:payload), :frozen?
    end

    def test_draft_from_normalized_hash_preserves_explicit_lineage
      lineage = Julewire::Core::Execution::Lineage.new(
        reference: { type: "job", id: "child" },
        root_reference: { type: "request", id: "root" },
        parent_reference: { type: "job", id: "parent" },
        depth: 3
      )

      draft = Julewire::Core::Records::Draft.from_normalized_hash(
        normalized_record(execution: { type: "job", id: "child", ancestors: [{ id: "stale" }] }),
        lineage: lineage
      )

      assert_same lineage, draft.lineage
      assert_false draft.fetch(:execution).key?(:ancestors)
      assert_equal 3, draft.lineage.depth
    end

    def test_draft_from_normalized_hash_owns_mutable_sections
      input = normalized_record(payload: { ids: ["one"] })

      draft = Julewire::Core::Records::Draft.from_normalized_hash(input)

      refute_same input.fetch(:payload), draft.fetch(:payload)
      refute_predicate draft.fetch(:payload), :frozen?
      draft.fetch(:payload).fetch(:ids) << "two"

      assert_equal ["one"], input.dig(:payload, :ids)
      assert_equal %w[one two], draft.dig(:payload, :ids)
    end

    def test_draft_from_normalized_hash_finalizes_shallow_frozen_nested_input_defensively
      unfrozen_child = ["one"]
      frozen_parent = { child: unfrozen_child }.freeze
      draft = Julewire::Core::Records::Draft.from_normalized_hash(
        normalized_record(payload: { frozen_parent: frozen_parent })
      )

      record = draft.to_record

      assert_predicate record.dig(:payload, :frozen_parent, :child), :frozen?
    end

    def test_record_from_owned_hash_cleans_lazy_lineage_keys_in_place
      input = normalized_record(
        execution: {
          type: "job",
          id: "child",
          depth: 2,
          ancestors: [{ type: "request", id: "root" }],
          ancestors_truncated: true
        },
        payload: { ids: ["one"] }
      )

      record = Julewire::Core::Records::Record.from_owned_hash(input)

      assert_same input, record.serializable_data
      assert_false input.fetch(:execution).key?(:ancestors)
      assert_false input.fetch(:execution).key?(:ancestors_truncated)
      assert_equal [{ type: "request", id: "root" }], record.lineage.ancestors
      assert_predicate record.fetch(:payload), :frozen?
    end

    def test_record_from_owned_hash_cleans_hash_subclass_lineage_keys
      input = Class.new(Hash).new.merge!(
        normalized_record(execution: { type: "job", id: "child", ancestors: [{ id: "root" }] })
      )

      record = Julewire::Core::Records::Record.from_owned_hash(input)

      assert_same input, record.serializable_data
      assert_equal [{ id: "root" }], record.lineage.ancestors
      assert_false record.fetch(:execution).key?(:ancestors)
    end

    def test_record_from_owned_hash_does_not_mutate_frozen_input
      input = Julewire::Core::Serialization::DeepFreeze.call(
        normalized_record(execution: { type: "job", id: "child", ancestors: [{ id: "root" }] })
      )

      record = Julewire::Core::Records::Record.from_owned_hash(input)

      assert_true input.fetch(:execution).key?(:ancestors)
      refute_same input, record.serializable_data
      assert_false record.fetch(:execution).key?(:ancestors)
    end

    def test_record_from_owned_hash_rejects_non_hash_values
      error = assert_raises(TypeError) do
        Julewire::Core::Records::Record.from_owned_hash("not a record")
      end

      assert_equal "record must be a normalized Hash", error.message
    end

    def test_record_from_owned_hash_rejects_nested_string_keys
      input = normalized_record(payload: { nested: { "bad" => true } })

      error = assert_raises(TypeError) do
        Julewire::Core::Records::Record.from_owned_hash(input)
      end

      assert_equal "record must not use string keys", error.message
    end

    def test_record_from_owned_hash_default_freezes_children_inside_frozen_sections
      ids = ["one"]
      payload = { ids: ids }.freeze
      input = normalized_record(payload: payload)

      record = Julewire::Core::Records::Record.from_owned_hash(input)

      assert_predicate record.dig(:payload, :ids), :frozen?
    end

    def test_record_from_owned_hash_can_trust_frozen_sections
      ids = ["one"]
      payload = { ids: ids }.freeze
      input = normalized_record(payload: payload)

      record = Julewire::Core::Records::Record.from_owned_hash(input, trust_frozen: true)

      assert_same payload, record.fetch(:payload)
      refute_predicate ids, :frozen?
    end

    private

    def documented_record_keys(body)
      hash = Prism.parse(body).value.statements.body.fetch(0)
      hash.elements.map { it.key.unescaped.to_sym }
    end
  end
end
