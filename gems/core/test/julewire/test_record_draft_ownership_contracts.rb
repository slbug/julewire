# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestRecordDraftOwnershipContracts < Minitest::Test
    cover Julewire::Core::Records::Draft
    cover "Julewire::Core::Records::Draft::Builder*"

    def test_mutable_draft_freezes_nested_values_inside_shallow_frozen_containers
      draft = Core::Records::Draft.build(
        {
          payload: {
            frozen_hash: { values: [] }.freeze,
            frozen_array: [{ value: "x" }].freeze
          }
        },
        context: {},
        scope: nil
      )

      record = draft.to_record

      assert_predicate record.dig(:payload, :frozen_hash, :values), :frozen?
      assert_predicate record.dig(:payload, :frozen_array, 0), :frozen?
    end

    def test_immutable_record_can_round_trip_without_mutation
      record = Core::Records::Draft.build({ payload: { count: 1 } }, context: {}, scope: nil).to_record

      round_trip = Core::Records::Draft.from_record(record).to_record

      assert_equal({ count: 1 }, round_trip.fetch(:payload))
      assert_predicate record.fetch(:payload), :frozen?
    end

    def test_mutable_draft_duplicates_scalar_strings_without_freezing
      message = +"mutable message"

      draft = Core::Records::Draft.build(
        { message: message },
        context: {},
        scope: nil
      )

      refute_same message, draft.fetch(:message)
      assert_equal "mutable message", draft.fetch(:message)
      refute_predicate draft.fetch(:message), :frozen?

      message.replace("changed")

      assert_equal "mutable message", draft.fetch(:message)
    end

    def test_record_finalization_freezes_duplicated_scalar_strings
      message = +"mutable message"

      draft = Core::Records::Draft.build({ message: message }, context: {}, scope: nil)
      record = draft.to_record

      refute_same message, draft.fetch(:message)
      assert_equal "mutable message", draft.fetch(:message)
      assert_predicate record.fetch(:message), :frozen?

      message.replace("changed")

      assert_equal "mutable message", record.fetch(:message)
    end

    def test_frozen_scalar_strings_are_copied_into_the_mutable_draft
      message = "frozen message"

      draft = Core::Records::Draft.build({ message: message }, context: {}, scope: nil)

      refute_same message, draft.fetch(:message)
      refute_predicate draft.fetch(:message), :frozen?

      draft.fetch(:message).replace("changed")

      assert_equal "frozen message", message
    end

    def test_non_string_scalar_values_are_preserved
      marker = Object.new

      draft = Core::Records::Draft.build({ message: 42, logger: false, source: marker }, context: {}, scope: nil)

      assert_equal 42, draft.fetch(:message)
      assert_false draft.fetch(:logger)
      assert_same marker, draft.fetch(:source)
    end

    def test_string_subclasses_are_treated_as_strings
      message = Class.new(String).new("subclass message")

      draft = Core::Records::Draft.build({ message: message }, context: {}, scope: nil)

      refute_same message, draft.fetch(:message)
      assert_equal "subclass message", draft.fetch(:message)
      refute_predicate draft.fetch(:message), :frozen?
    end

    def test_owned_scalar_strings_are_copied_without_mutating_the_caller
      message = +"owned message"

      draft = build_pipeline_draft({ message: message }, input_owned: true)

      refute_same message, draft.fetch(:message)
      refute_predicate draft.fetch(:message), :frozen?

      draft.fetch(:message).replace("changed")

      assert_equal "owned message", message
    end

    def test_owned_hash_sections_are_copied_into_the_mutable_draft
      payload = { token: +"secret" }

      draft = build_pipeline_draft(
        { payload: payload },
        input_owned: true
      )

      refute_same payload, draft.fetch(:payload)
      refute_predicate draft.fetch(:payload), :frozen?
      refute_predicate draft.dig(:payload, :token), :frozen?

      payload[:token].replace("changed")

      assert_equal "secret", draft.dig(:payload, :token)
    end

    def test_pipeline_owned_builder_treats_input_as_unowned_by_default
      error = assert_raises(ArgumentError) do
        build_pipeline_draft({ payload: { _julewire_truncation: symbol_truncation_metadata } })
      end

      assert_equal "_julewire_truncation is reserved for Julewire truncation metadata", error.message
    end

    def test_explicit_owned_input_preserves_truncation_metadata
      metadata = symbol_truncation_metadata

      draft = build_pipeline_draft(
        { payload: { _julewire_truncation: metadata, token: "secret" } },
        input_owned: true
      )

      assert_symbol_truncation_metadata draft.dig(:payload, :_julewire_truncation),
                                        fields: ["field"]
      assert_equal "secret", draft.dig(:payload, :token)
    end

    def test_owned_base_metadata_merges_with_unowned_input
      metadata = symbol_truncation_metadata
      base_neutral = { _julewire_truncation: metadata, kept: "base" }.freeze

      draft = build_pipeline_draft(
        { neutral: { added: "input" } },
        neutral: base_neutral
      )

      assert_symbol_truncation_metadata draft.dig(:neutral, :_julewire_truncation),
                                        fields: ["field"]
      assert_equal "base", draft.dig(:neutral, :kept)
      assert_equal "input", draft.dig(:neutral, :added)
    end

    def test_owned_error_metadata_is_preserved
      metadata = symbol_truncation_metadata
      error_hash = { message: "boom", _julewire_truncation: metadata }

      draft = build_pipeline_draft(
        { error: error_hash },
        input_owned: true
      )

      refute_same error_hash, draft.fetch(:error)
      assert_equal "boom", draft.dig(:error, :message)
      assert_symbol_truncation_metadata draft.dig(:error, :_julewire_truncation),
                                        fields: ["field"]
    end

    def test_unowned_error_hash_rejects_reserved_metadata
      error = assert_raises(ArgumentError) do
        Core::Records::Draft.build(
          { error: { _julewire_truncation: symbol_truncation_metadata } },
          context: {},
          scope: nil
        )
      end

      assert_equal "_julewire_truncation is reserved for Julewire truncation metadata", error.message
    end

    def test_draft_builders_copy_scope_execution_into_mutable_sections
      scope = Core::Execution::Scope.new(type: :job, id: "job-1")
      frozen_execution = scope.frozen_execution_hash

      pipeline_draft = build_pipeline_draft({}, scope: scope, input_owned: true)
      public_draft = Core::Records::Draft.build({}, context: {}, scope: scope)

      [pipeline_draft, public_draft].each do |draft|
        refute_same frozen_execution, draft.fetch(:execution)
        assert_equal frozen_execution, draft.fetch(:execution)
        refute_predicate draft.fetch(:execution), :frozen?
      end
    end

    def test_pipeline_draft_preserves_the_scope_lineage_object
      parent = Core::Execution::Scope.new(type: :request, id: "request-1")
      scope = Core::Execution::Scope.new(type: :job, id: "job-1", parent: parent)

      draft = build_pipeline_draft({}, scope: scope, input_owned: true)

      assert_same scope.lineage, draft.lineage
      assert_equal({ type: "request", id: "request-1" }, draft.lineage.root_reference)
    end

    def test_defensive_draft_preserves_owned_scope_execution_metadata
      metadata = symbol_truncation_metadata
      scope = Core::Execution::Scope.new(
        type: :job,
        execution: { _julewire_truncation: metadata },
        execution_owned: true
      )

      draft = Core::Records::Draft.build({}, context: {}, scope: scope)

      assert_symbol_truncation_metadata draft.dig(:execution, :_julewire_truncation),
                                        fields: ["field"]
      refute_same scope.frozen_execution_hash, draft.fetch(:execution)
    end

    def test_owned_execution_relationships_are_cleaned_without_mutating_input
      execution = {
        type: "job",
        id: "job-1",
        depth: 9,
        root: { type: "request", id: "request-1" },
        parent: { type: "controller", id: "controller-1" }
      }

      draft = build_pipeline_draft(
        { execution: execution },
        input_owned: true
      )

      refute_same execution, draft.fetch(:execution)
      assert_equal({ type: "job", id: "job-1" }, draft.fetch(:execution))
      assert_equal 9, execution.fetch(:depth)
      assert_equal({ type: "request", id: "request-1" }, execution.fetch(:root))
    end

    def test_static_scope_and_input_labels_merge_without_mutating_static_labels
      static_labels = { service: "api" }
      scope = Core::Execution::Scope.new(type: :request, id: "request-1", labels: { request: "checkout" })

      draft = Core::Records::Draft.build(
        { labels: { env: "test" } },
        context: {},
        scope: scope,
        static_labels: static_labels
      )

      assert_equal({ service: "api", request: "checkout", env: "test" }, draft.fetch(:labels))
      assert_equal({ service: "api" }, static_labels)
    end

    def test_scope_labels_are_copied_when_static_labels_are_empty
      scope = Core::Execution::Scope.new(type: :request, id: "request-1", labels: { request: "checkout" })
      scope_labels = scope.frozen_labels_hash

      draft = Core::Records::Draft.build({}, context: {}, scope: scope, static_labels: nil)

      assert_equal scope_labels, draft.fetch(:labels)
      refute_same scope_labels, draft.fetch(:labels)
      refute_predicate draft.fetch(:labels), :frozen?
    end

    def test_owned_pipeline_draft_copies_scope_labels_when_static_labels_are_empty
      scope = Core::Execution::Scope.new(type: :request, id: "request-1", labels: { request: "checkout" })
      scope_labels = scope.frozen_labels_hash

      draft = build_pipeline_draft(
        {},
        scope: scope,
        input_owned: true
      )

      assert_equal scope_labels, draft.fetch(:labels)
      refute_same scope_labels, draft.fetch(:labels)
      refute_predicate draft.fetch(:labels), :frozen?
    end

    def test_owned_record_input_requires_hash_contract
      error = assert_raises(TypeError) do
        build_pipeline_draft("owned message", input_owned: true)
      end

      assert_equal "owned record input must be a Hash", error.message
    end

    def test_pipeline_owned_draft_uses_default_invalid_severity_reporter
      reported = []
      severity = Object.new

      with_overridden_singleton_method(
        Core::Diagnostics::InvalidSeverityReporter,
        :call,
        proc { |value| reported << value }
      ) do
        draft = build_pipeline_draft({ severity: severity })

        assert_equal :info, draft.fetch(:severity)
      end

      assert_equal [severity], reported
    end

    def test_pipeline_owned_draft_uses_default_error_backtrace_limit
      error = RuntimeError.new("boom")
      error.set_backtrace(Array.new(Core::MAX_BACKTRACE_LINES + 2) { |index| "app.rb:#{index}:in `call'" })

      draft = build_pipeline_draft({ error: error })

      assert_equal Core::MAX_BACKTRACE_LINES, draft.dig(:error, :backtrace).length
    end

    def test_owned_error_backtrace_limiting_does_not_modify_the_input
      root_backtrace = %w[root-1.rb root-2.rb]
      cause_backtrace = %w[cause-1.rb cause-2.rb]
      error = {
        message: "root",
        backtrace: root_backtrace,
        cause: { message: "cause", backtrace: cause_backtrace }
      }

      draft = build_pipeline_draft(
        { error: error },
        error_backtrace_lines: 1,
        input_owned: true
      )

      assert_equal ["root-1.rb"], draft.dig(:error, :backtrace)
      assert_equal ["cause-1.rb"], draft.dig(:error, :cause, :backtrace)
      assert_equal %w[root-1.rb root-2.rb], error.fetch(:backtrace)
      assert_equal %w[cause-1.rb cause-2.rb], error.dig(:cause, :backtrace)
    end

    def test_unowned_scalar_record_input_uses_to_s_message
      input = Object.new
      input.define_singleton_method(:to_s) { "object message" }

      draft = Core::Records::Draft.build(input, context: {}, scope: nil)

      assert_equal "object message", draft.fetch(:message)
    end

    def test_error_exception_section_is_mutable_until_record_finalization
      draft = Core::Records::Draft.build({ error: RuntimeError.new("boom") }, context: {}, scope: nil)

      refute_predicate draft[:error], :frozen?
      refute_predicate draft.dig(:error, :message), :frozen?

      record = draft.to_record

      assert_predicate record[:error], :frozen?
      assert_predicate record.dig(:error, :message), :frozen?
    end

    def test_error_hash_section_is_symbolized_bounded_and_finalized_immutable
      draft = Core::Records::Draft.build(
        { error: { "class" => "RuntimeError", "message" => "boom", "backtrace" => %w[a.rb b.rb] } },
        context: {},
        error_backtrace_lines: 1,
        scope: nil
      )

      assert_equal "RuntimeError", draft.dig(:error, :class)
      assert_equal ["a.rb"], draft.dig(:error, :backtrace)
      refute_predicate draft[:error], :frozen?

      record = draft.to_record

      assert_predicate record[:error], :frozen?
      assert_predicate record.dig(:error, :message), :frozen?
    end

    def test_non_exception_error_is_stringified_and_copied
      message = +"custom error"
      error = Object.new
      error.define_singleton_method(:to_s) { message }

      draft = Core::Records::Draft.build({ error: error }, context: {}, scope: nil)
      message.replace("changed")

      assert_equal({ message: "custom error" }, draft[:error])
    end

    private

    def build_pipeline_draft(input = {}, context: {}, scope: nil, **)
      Core::Records::Draft.build_pipeline_owned(input, context: context, scope: scope, **)
    end

    def symbol_truncation_metadata
      {
        truncated: true,
        truncated_fields: ["field"],
        limits: {
          max_array_items: nil,
          max_depth: 20,
          max_hash_keys: nil,
          max_string_bytes: 10
        }
      }
    end
  end
end
