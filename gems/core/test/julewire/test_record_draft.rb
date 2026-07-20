# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestRecordDraft < Minitest::Test
    cover Julewire::Core::Records::Draft
    cover Julewire::Core::Records::Record
    cover "Julewire::Core::Records::Draft::Builder*"

    def test_record_draft_allows_direct_mutation_before_final_immutable_record
      draft = Julewire::Core::Records::Draft.build(
        { payload: { "token" => "secret" } },
        context: {},
        scope: nil
      )

      draft[:payload][:token] = "[FILTERED]"
      draft[:payload][:processed] = true
      draft[:severity] = :warn

      record = draft.to_record

      assert_instance_of Julewire::Core::Records::Record, record
      assert_equal :warn, record.fetch(:severity)
      assert_equal({ token: "[FILTERED]", processed: true }, record.fetch(:payload))
      assert_predicate record.fetch(:payload), :frozen?
    end

    def test_record_draft_build_accepts_default_empty_input
      draft = Julewire::Core::Records::Draft.build(context: {}, scope: nil)

      assert_predicate draft.fetch(:timestamp), :utc?
      assert_predicate draft.fetch(:timestamp), :frozen?

      record = draft.to_record

      assert_equal "log", record.fetch(:event)
      assert_equal :point, record.fetch(:kind)
      assert_empty record.fetch(:payload)
    end

    def test_record_draft_copies_owned_event_into_mutable_state
      event = +"created"
      draft = Julewire::Core::Records::Draft.build_pipeline_owned(
        { event: event },
        context: {},
        scope: nil,
        input_owned: true
      )

      assert_equal "created", draft.fetch(:event)
      refute_predicate draft.fetch(:event), :frozen?
      refute_same event, draft.fetch(:event)

      draft.fetch(:event).replace("updated")

      assert_equal "created", event
    end

    def test_record_draft_enumerates_owned_record_data
      draft = draft_with_payload(count: 1)
      keys = []

      pairs = draft.map { |key, value| [key, value] }
      draft.each_key { keys << it }

      assert_includes pairs, [:payload, { count: 1 }]
      assert_includes keys, :payload
      assert_includes draft.each.to_h.fetch(:payload), :count
      assert_includes draft.each_key.to_a, :payload
    end

    def test_record_draft_accepts_normalized_summary_kind
      record = Julewire::Core::Records::Draft.build({ kind: :summary }, context: {}, scope: nil).to_record

      assert_equal :summary, record.fetch(:kind)
    end

    def test_record_draft_accepts_string_summary_kind
      record = Julewire::Core::Records::Draft.build({ kind: "summary" }, context: {}, scope: nil).to_record

      assert_equal :summary, record.fetch(:kind)
    end

    def test_record_draft_rejects_unsupported_input_kind
      error = assert_raises(ArgumentError) do
        Julewire::Core::Records::Draft.build({ kind: Object.new }, context: {}, scope: nil)
      end

      assert_match(/\Aunsupported record kind: #<Object:/, error.message)
    end

    def test_record_draft_rejects_unsupported_string_kind_with_inspected_value
      error = assert_raises(ArgumentError) do
        Julewire::Core::Records::Draft.build({ kind: "event" }, context: {}, scope: nil)
      end

      assert_equal 'unsupported record kind: "event"', error.message
    end

    def test_record_draft_defers_direct_mutation_validation_until_record_boundary
      draft = Julewire::Core::Records::Draft.build({}, context: {}, scope: nil)

      draft[:kind] = :bad
      error = assert_raises(TypeError) { draft.to_record }

      assert_equal "record kind must be :point or :summary", error.message
    end

    def test_record_draft_defers_direct_section_validation_until_record_boundary
      draft = draft_with_payload

      draft[:payload] = nil
      error = assert_raises(TypeError) { draft.to_record }

      assert_equal "record payload must be a Hash", error.message
    end

    def test_record_draft_can_be_built_from_immutable_record_without_sharing_sections
      record = record_with_count_payload

      draft = Julewire::Core::Records::Draft.from_record(record)
      draft[:payload] = { count: 2 }

      assert_equal({ count: 1 }, record.fetch(:payload))
      assert_equal({ count: 2 }, draft.fetch(:payload))
    end

    def test_record_draft_from_record_provides_a_mutable_owned_copy
      record = record_with_count_payload

      draft = Julewire::Core::Records::Draft.from_record(record)

      refute_predicate draft.fetch(:payload), :frozen?
      draft.fetch(:payload)[:count] = 2

      assert_equal 1, record.dig(:payload, :count)
      assert_equal 2, draft.dig(:payload, :count)
    end

    def test_record_draft_from_record_requires_real_record_instance
      record = record_with_count_payload
      recordish = Object.new
      recordish.define_singleton_method(:to_h) { record.to_h }
      recordish.define_singleton_method(:lineage) { record.lineage }

      error = assert_raises(TypeError) do
        Julewire::Core::Records::Draft.from_record(recordish)
      end

      assert_equal "expected Julewire::Record", error.message
    end

    def test_record_draft_from_record_preserves_record_lineage
      record = record_with_count_payload

      draft = Julewire::Core::Records::Draft.from_record(record)

      assert_same record.lineage, draft.lineage
    end

    def test_record_draft_non_execution_assignment_preserves_lineage_cache
      lineage = Julewire::Core::Execution::Lineage.from_execution_hash({ type: "job", id: "job-1" })
      draft = Julewire::Core::Records::Draft.from_normalized_hash(normalized_record, lineage: lineage)

      draft[:payload] = { count: 1 }

      assert_same lineage, draft.lineage
    end

    def test_record_draft_transform_field_yields_current_value
      draft = draft_with_payload(count: 1)

      draft.transform_field!(:payload) do |payload|
        assert_equal({ count: 1 }, payload)
        payload.merge(processed: true)
      end

      assert_equal({ count: 1, processed: true }, draft.fetch(:payload))
    end

    def test_record_draft_builds_attributes_section
      record = Julewire::Core::Records::Draft.build(
        {
          attributes: {
            "my_app.request_method" => "GET",
            web: { "controller" => "HomeController" }
          }
        },
        context: {},
        scope: nil
      ).to_record

      assert_equal "GET", record.dig(:attributes, :"my_app.request_method")
      assert_equal "HomeController", record.dig(:attributes, :web, :controller)
    end

    def test_record_draft_build_forwards_public_record_fields
      timestamp = Time.utc(2026, 7, 4, 12, 30, 0)
      event = Object.new
      event.define_singleton_method(:to_s) { "custom.event" }
      payload = Class.new(Hash)[attempt: 2]
      metrics = Class.new(Hash)["duration_ms" => 12.5]

      draft = Julewire::Core::Records::Draft.build(
        {
          timestamp: timestamp,
          severity: :warn,
          kind: :summary,
          event: event,
          message: "done",
          logger: "app.logger",
          source: "worker",
          payload: payload,
          metrics: metrics,
          error: nil
        },
        context: { request_id: "request-1" },
        carry: { trace_id: "trace-1" },
        neutral: { "job.name" => "ImportJob" },
        attributes: { account: { id: "acct-1" } },
        static_labels: { service: "worker" },
        scope: nil
      )
      record = draft.to_record

      assert_equal timestamp, record.fetch(:timestamp)
      assert_predicate record.fetch(:timestamp), :frozen?
      refute_predicate timestamp, :frozen?
      assert_equal :warn, record.fetch(:severity)
      assert_equal :summary, record.fetch(:kind)
      assert_equal "custom.event", record.fetch(:event)
      assert_equal "done", record.fetch(:message)
      assert_equal "app.logger", record.fetch(:logger)
      assert_equal "worker", record.fetch(:source)
      assert_equal({ attempt: 2 }, record.fetch(:payload))
      assert_equal({ duration_ms: 12.5 }, record.fetch(:metrics))
      assert_nil record.fetch(:error)
      assert_equal "request-1", record.dig(:context, :request_id)
      assert_equal "trace-1", record.dig(:carry, :trace_id)
      assert_equal "ImportJob", record.dig(:neutral, :"job.name")
      assert_equal "acct-1", record.dig(:attributes, :account, :id)
      assert_equal "worker", record.dig(:labels, :service)
    end

    def test_record_draft_build_does_not_report_omitted_severity
      reported = []

      draft = Julewire::Core::Records::Draft.build(
        {},
        context: {},
        scope: nil,
        invalid_severity_reporter: ->(value) { reported << value }
      )

      assert_equal :info, draft.fetch(:severity)
      assert_empty reported
    end

    def test_record_draft_wraps_scalar_payload_and_metrics
      record = Julewire::Core::Records::Draft.build(
        { payload: false, metrics: 0 },
        context: {},
        scope: nil
      ).to_record

      assert_equal({ value: false }, record.fetch(:payload))
      assert_equal({ value: 0 }, record.fetch(:metrics))
    end

    def test_record_draft_copies_scope_execution_without_explicit_execution_input
      scope = build_execution_scope(
        type: :request,
        id: "request-1",
        execution: { custom: { ids: ["one"] } }
      )

      draft = Julewire::Core::Records::Draft.build({}, context: {}, scope: scope)
      record = draft.to_record

      assert_equal ["one"], record.dig(:execution, :custom, :ids)
      assert_equal ["one"], scope.execution_hash.dig(:custom, :ids)
      assert_raises(FrozenError) { record.dig(:execution, :custom, :ids) << "two" }
    end

    def test_record_draft_deep_merges_input_attributes_with_base_attributes
      record = Julewire::Core::Records::Draft.build(
        { attributes: { web: { action: "index" } } },
        context: {},
        scope: nil,
        attributes: { web: { controller: "HomeController" } }
      ).to_record

      assert_equal "HomeController", record.dig(:attributes, :web, :controller)
      assert_equal "index", record.dig(:attributes, :web, :action)
    end

    def test_record_draft_build_pipeline_owned_keeps_owned_base_sections_with_input_override
      base_neutral = { "job.name": "Worker" }.freeze
      base_carry = { trace_id: "trace-1" }.freeze
      record = Julewire::Core::Records::Draft.build_pipeline_owned(
        { neutral: { "job.name": "Importer" }, message: "done" },
        context: {},
        carry: base_carry,
        neutral: base_neutral,
        scope: nil
      ).to_record

      assert_equal "Importer", record.dig(:neutral, :"job.name")
      assert_equal "trace-1", record.dig(:carry, :trace_id)
    end

    def test_record_draft_treats_nil_base_sections_as_empty
      record = Julewire::Core::Records::Draft.build(
        {
          attributes: { account: { id: "acct-1" } },
          carry: { trace: { id: "trace-1" } },
          context: { request_id: "request-1" },
          neutral: { http: { method: "GET" } }
        },
        attributes: nil,
        carry: nil,
        context: nil,
        neutral: nil,
        scope: nil
      ).to_record

      assert_equal "acct-1", record.dig(:attributes, :account, :id)
      assert_equal "trace-1", record.dig(:carry, :trace, :id)
      assert_equal "request-1", record.dig(:context, :request_id)
      assert_equal "GET", record.dig(:neutral, :http, :method)
    end

    def test_record_draft_static_labels_are_optional_and_preserved
      unlabeled = Julewire::Core::Records::Draft.build({}, context: {}, scope: nil, static_labels: nil).to_record
      labeled = Julewire::Core::Records::Draft.build(
        {},
        context: {},
        scope: nil,
        static_labels: { "service" => "checkout" }
      ).to_record

      assert_empty unlabeled.fetch(:labels)
      assert_equal "checkout", labeled.dig(:labels, :service)
    end

    def test_record_draft_context_merge_replaces_nested_hashes_and_keeps_base_immutable
      base = { account: { id: "acct-1", role: "admin" } }

      draft = Julewire::Core::Records::Draft.build(
        { context: { account: { id: "acct-2" }, depth: "context-depth" } },
        context: base,
        scope: nil
      )

      assert_equal({ account: { id: "acct-2" }, depth: "context-depth" }, draft.fetch(:context))
      assert_equal({ account: { id: "acct-1", role: "admin" } }, base)
      refute_predicate draft.fetch(:context), :frozen?
    end

    def test_record_draft_base_empty_execution_is_cleaned_and_mutable
      draft = Julewire::Core::Records::Draft.build(
        { execution: { type: "job", id: "job-1", depth: 9, root: { id: "root" } } },
        context: {},
        scope: nil
      )

      assert_equal({ type: "job", id: "job-1" }, draft.fetch(:execution))
      refute_predicate draft.fetch(:execution), :frozen?
    end

    def test_record_draft_transforms_whole_data
      draft = draft_with_payload

      draft.transform_record! { |data| data.merge(payload: { token: "[FILTERED]" }) }

      assert_equal({ token: "[FILTERED]" }, draft.fetch(:payload))
    end

    def test_record_draft_transform_is_validated_at_record_boundary
      draft = draft_with_payload

      draft.transform_record! { it.merge(payload: nil) }
      error = assert_raises(TypeError) { draft.to_record }

      assert_equal "record payload must be a Hash", error.message
      assert_nil draft.fetch(:payload)
    end

    def test_record_draft_validate_returns_self_for_valid_current_data
      draft = draft_with_payload

      assert_same draft, draft.validate!
    end

    def test_record_draft_validate_rejects_invalid_current_data
      draft = draft_with_payload

      draft[:kind] = :bad
      error = assert_raises(TypeError) { draft.validate! }

      assert_equal "record kind must be :point or :summary", error.message
    end

    def test_record_draft_allows_temporary_non_hash_transform_until_record_boundary
      draft = draft_with_payload

      draft.transform_record! { "bad" }
      error = assert_raises(TypeError) { draft.to_record }

      assert_equal "record must be a normalized Hash", error.message
    end

    def test_record_draft_keeps_sections_mutable_until_record_boundary
      draft = Julewire::Core::Records::Draft.build(
        { payload: { tags: ["first"] } },
        context: {},
        scope: nil
      )

      draft[:payload][:tags] << "second"
      draft[:payload][:nested] = { value: 1 }
      draft[:payload][:nested][:value] = 2

      record = draft.to_record

      assert_equal %w[first second], record.dig(:payload, :tags)
      assert_equal 2, record.dig(:payload, :nested, :value)
      assert_predicate record.fetch(:payload), :frozen?
    end

    def test_record_draft_can_merge_missing_optional_sections
      draft = Julewire::Core::Records::Draft.build({}, context: {}, scope: nil)

      draft[:metrics] = { duration_ms: 12.3 }

      assert_equal({ duration_ms: 12.3 }, draft.fetch(:metrics))
    end

    def test_record_draft_does_not_share_context_or_carry_inputs
      context = { account: { id: "acct-1" } }
      carry = { trace: { id: "trace-1" } }
      draft = Julewire::Core::Records::Draft.build(
        {},
        context: context,
        carry: carry,
        scope: nil
      )

      draft[:context][:account][:id] = "mutated"
      draft[:carry][:trace][:id] = "mutated"

      assert_equal "mutated", draft.dig(:context, :account, :id)
      assert_equal "mutated", draft.dig(:carry, :trace, :id)
      assert_equal "acct-1", context.dig(:account, :id)
      assert_equal "trace-1", carry.dig(:trace, :id)
    end

    def test_immutable_record_freezes_finalized_draft_sections
      draft = Julewire::Core::Records::Draft.build(
        { payload: { body: "x" * 4_096 } },
        context: { account: { id: "acct-1" } },
        scope: nil
      )
      record = draft.to_record

      assert_predicate record[:context], :frozen?
      assert_predicate record[:payload], :frozen?
      assert_predicate record.dig(:context, :account), :frozen?
      assert_predicate record.dig(:payload, :body), :frozen?
    end

    def test_to_record_is_idempotent_after_freezing_draft_data
      draft = draft_with_payload(count: 1)

      first = draft.to_record
      second = draft.to_record

      assert_same first, second
      assert_equal 1, second.dig(:payload, :count)
    end

    def test_record_draft_moves_ancestors_to_lineage_accessor
      draft = Julewire::Core::Records::Draft.build(
        {
          execution: {
            type: "job",
            id: "job-1",
            ancestors: [{ type: "request", id: "request-1" }],
            ancestors_truncated: true
          }
        },
        context: {},
        scope: nil
      )

      assert_false draft[:execution].key?(:ancestors)
      assert_false draft[:execution].key?(:ancestors_truncated)
      assert_equal [{ type: "request", id: "request-1" }], draft.lineage.ancestors
      assert_predicate draft.lineage, :truncated?
    end

    def test_record_draft_updates_lineage_when_execution_section_changes
      draft = Julewire::Core::Records::Draft.build({}, context: {}, scope: nil)

      draft[:execution] = {
        type: "job",
        id: "job-1",
        ancestors: [{ type: "request", id: "request-1" }]
      }

      assert_equal "job-1", draft[:execution][:id]
      assert_equal [{ type: "request", id: "request-1" }], draft.lineage.ancestors

      record = draft.to_record

      assert_false record[:execution].key?(:ancestors)
      assert_equal [{ type: "request", id: "request-1" }], record.lineage.ancestors
    end

    def test_record_draft_allows_invalid_execution_mutation_until_record_boundary
      draft = Julewire::Core::Records::Draft.build(
        {
          execution: {
            type: "job",
            id: "job-1",
            ancestors: [{ type: "request", id: "request-1" }]
          }
        },
        context: {},
        scope: nil
      )

      draft[:execution] = "invalid"

      assert_equal "invalid", draft[:execution]
      assert_empty draft.lineage.ancestors

      error = assert_raises(TypeError) { draft.to_record }

      assert_equal "record execution must be a Hash", error.message
    end

    def test_transform_record_rebuilds_lineage_for_execution_changes
      draft = Julewire::Core::Records::Draft.build({}, context: {}, scope: nil)

      assert_empty draft.lineage.ancestors

      draft.transform_record! do |data|
        data.merge(
          execution: {
            type: "job",
            id: "job-1",
            ancestors: [{ type: "request", id: "request-1" }]
          }
        )
      end

      record = draft.to_record

      assert_false record[:execution].key?(:ancestors)
      assert_equal [{ type: "request", id: "request-1" }], record.lineage.ancestors
    end

    private

    def record_with_count_payload
      draft_with_payload(count: 1).to_record
    end

    def draft_with_payload(payload = { token: "secret" })
      Julewire::Core::Records::Draft.build({ payload: payload }, context: {}, scope: nil)
    end
  end
end
