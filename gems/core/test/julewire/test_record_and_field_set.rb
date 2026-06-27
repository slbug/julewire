# frozen_string_literal: true

require "test_helper"
require "json"

module Julewire
  class TestRecordAndFieldSetHardening < Minitest::Test
    cover Julewire::Core::Serialization
    cover Julewire::Core::Fields::FieldSet
    cover Julewire::Core::Records::Record
    cover Julewire::Core::Records::Draft
    def test_record_copies_and_freezes_containers_without_mutating_source
      source = { payload: { "message" => +"hello" } }

      record = build_record(source, context: {}, scope: nil)

      refute_predicate source, :frozen?
      refute_predicate source.fetch(:payload), :frozen?
      refute_predicate source.dig(:payload, "message"), :frozen?
      assert_predicate record, :frozen?
      assert_predicate record.fetch(:payload), :frozen?
      assert_predicate record.dig(:payload, :message), :frozen?
      refute_same source.fetch(:payload), record.fetch(:payload)
      refute_same source.dig(:payload, "message"), record.dig(:payload, :message)
    end

    def test_record_prunes_cycles
      source = {}
      source[:payload] = source

      record = build_record(source, context: {}, scope: nil)

      assert_equal "[Circular]", record.dig(:payload, :value)
      refute_predicate source, :frozen?
    end

    def test_field_set_deep_dup_prunes_circular_hashes
      cycle = {}
      cycle[:self] = cycle

      copy = Julewire::Core::Fields::FieldSet.deep_dup(cycle)

      assert_equal "[Circular]", copy[:self]
    end

    def test_field_set_deep_dup_protects_string_hash_keys
      key = +"field"
      source = { key => "value" }

      copy = Julewire::Core::Fields::FieldSet.deep_dup(source)
      key.replace("mutated")

      assert_equal "value", copy.fetch("field")
      assert_predicate copy.keys.first, :frozen?
    end

    def test_value_copy_freezes_time_values_when_requested
      timestamp = Time.now.utc

      copy = Julewire::Core::Serialization::ValueCopy.call(timestamp, freeze_values: true)

      refute_same timestamp, copy
      assert_predicate copy, :frozen?
      assert_true Ractor.shareable?(copy)
    end

    def test_field_set_deep_dup_tolerates_reentrant_copy
      reentrant_hash_class = Class.new(Hash) do
        def each(&)
          Julewire::Core::Fields::FieldSet.deep_dup(inner: "ok")
          super
        end
      end
      source = reentrant_hash_class[outer: { value: "ok" }]

      assert_equal(
        { outer: { value: "ok" } },
        Julewire::Core::Fields::FieldSet.deep_dup(source)
      )
    end

    def test_json_encoder_serializes_objects_with_bounded_fallback
      object = Object.new
      def object.inspect
        raise "broken"
      end

      record = JSON.parse(
        Julewire::Core::Serialization::JsonEncoder.new.call(
          Julewire::Core::Records::Formatter.new.call(
            build_record({ payload: { object: object } }, context: {}, scope: nil)
          )
        )
      )

      assert_equal "[Object: Object]", record.dig("payload", "object")
    end

    def test_field_set_ignores_non_hash_inputs
      target = { count: 1 }

      assert_same target, Julewire::Core::Fields::FieldSet.merge!(target, "not a hash")
      assert_equal({ count: 1 }, target)
      assert_equal :fallback, Julewire::Core::Fields::FieldSet.value_for("not a hash", :payload, default: :fallback)
    end

    def test_record_accepts_json_style_string_keys
      record = build_record(
        {
          "event" => "json.event",
          "message" => "json message",
          "logger" => "JsonLogger",
          "payload" => { "count" => 1 },
          "metrics" => { "duration" => 2 }
        },
        context: {},
        scope: nil
      )

      assert_equal "json.event", record[:event]
      assert_equal "json message", record[:message]
      assert_equal "JsonLogger", record[:logger]
      assert_equal({ count: 1 }, record[:payload])
      assert_equal({ duration: 2 }, record[:metrics])
    end

    def test_record_rejects_unknown_kinds_without_symbolizing_unknown_values
      kind = Object.new

      def kind.to_sym
        raise "should not symbolize"
      end

      def kind.to_s
        "custom"
      end

      summary = build_record({ kind: "summary" }, context: {}, scope: nil)

      assert_raises(ArgumentError) do
        build_record({ kind: kind }, context: {}, scope: nil)
      end
      assert_equal :summary, summary[:kind]
    end

    def test_field_set_value_for_rejects_unsupported_key_types
      key = Object.new

      def key.to_sym
        raise "should not symbolize"
      end

      error = assert_raises(TypeError) do
        Julewire::Core::Fields::FieldSet.value_for({ safe: 1 }, key)
      end

      assert_equal "field keys must be String or Symbol", error.message
      assert_nil Julewire::Core::Fields::FieldSet.value_for({ "safe" => 1 }, :safe)
      assert_equal 1, Julewire::Core::Fields::FieldSet.value_for({ safe: 1 }, "safe")
    end

    def test_field_set_value_for_normalizes_string_keys
      fields = Array.new(32) { |index| [:"key#{index}", index] }.to_h

      assert_equal 31, Julewire::Core::Fields::FieldSet.value_for(fields, "key31")
      assert_nil Julewire::Core::Fields::FieldSet.value_for(fields, "missing")
    end

    def test_record_caps_error_backtrace
      error = RuntimeError.new("boom")
      error.set_backtrace(Array.new(30) { |index| "app.rb:#{index}" })

      record = build_record({ error: error }, context: {}, scope: nil)

      assert_equal 20, record.dig(:error, :backtrace).length
      assert_equal "app.rb:19", record.dig(:error, :backtrace).last
    end

    def test_record_omits_error_backtrace_when_limit_is_zero
      error = RuntimeError.new("boom")
      error.set_backtrace(["app.rb:1"])

      record = Julewire::Core::Records::Draft.build(
        { error: error },
        context: {},
        scope: nil,
        error_backtrace_lines: 0
      ).to_record

      refute_includes record.fetch(:error), :backtrace
    end

    def test_record_limits_core_shaped_error_hash_backtraces
      record = Julewire::Core::Records::Draft.build(
        {
          error: {
            class: "RuntimeError",
            message: "wrapper",
            backtrace: Array.new(5) { |index| "wrapper.rb:#{index}" },
            cause: {
              class: "ArgumentError",
              message: "cause",
              backtrace: Array.new(4) { |index| "cause.rb:#{index}" }
            }
          }
        },
        context: {},
        scope: nil,
        error_backtrace_lines: 2
      ).to_record

      assert_equal ["wrapper.rb:0", "wrapper.rb:1"], record.dig(:error, :backtrace)
      assert_equal ["cause.rb:0", "cause.rb:1"], record.dig(:error, :cause, :backtrace)
    end

    def test_record_omits_core_shaped_error_hash_backtraces_when_limit_is_zero
      record = Julewire::Core::Records::Draft.build(
        {
          error: {
            class: "RuntimeError",
            message: "wrapper",
            backtrace: ["wrapper.rb:1"],
            cause: {
              class: "ArgumentError",
              message: "cause",
              backtrace: ["cause.rb:1"]
            }
          }
        },
        context: {},
        scope: nil,
        error_backtrace_lines: 0
      ).to_record

      refute_includes record.fetch(:error), :backtrace
      refute_includes record.dig(:error, :cause), :backtrace
    end

    def test_record_promotes_only_generic_metrics_section
      record = build_record(
        {
          metrics: { count: 1 },
          http: { method: "GET" },
          request: { path: "/" },
          response: { status: 200 }
        },
        context: {},
        scope: nil
      )

      assert_equal({ count: 1 }, record[:metrics])
      refute_includes record, :http
      refute_includes record, :request
      refute_includes record, :response
    end

    def test_record_wraps_non_hash_structured_sections
      record = build_record(
        {
          context: "context",
          execution: "execution",
          labels: "labels",
          metrics: "metrics",
          payload: "payload"
        },
        context: {},
        scope: nil
      )

      assert_equal({ value: "context" }, record[:context])
      assert_equal({ value: "execution" }, record[:execution])
      assert_equal({ value: "labels" }, record[:labels])
      assert_equal({ value: "metrics" }, record[:metrics])
      assert_equal({ value: "payload" }, record[:payload])
    end

    def test_record_deep_dups_input_hash_sections
      base_context = { account: { id: "acct-1" } }
      token = +"secret"
      input = {
        context: { tenant: { id: "tenant-1" } },
        metrics: { count: { value: 1 } },
        payload: { item: { id: "item-1" }, token: token }
      }

      record = build_record(input, context: base_context, scope: nil)
      base_context[:account][:id] = "changed"
      input[:context][:tenant][:id] = "changed"
      input[:metrics][:count][:value] = 2
      input[:payload][:item][:id] = "changed"
      token << "-changed"

      assert_equal "acct-1", record.dig(:context, :account, :id)
      assert_equal "tenant-1", record.dig(:context, :tenant, :id)
      assert_equal 1, record.dig(:metrics, :count, :value)
      assert_equal "item-1", record.dig(:payload, :item, :id)
      assert_equal "secret", record.dig(:payload, :token)
    end
  end

  class TestFieldSetPublicApi < Minitest::Test
    cover Julewire::Core::Serialization
    cover Julewire::Core::Fields::FieldSet
    cover Julewire::Core::Records::Record
    cover Julewire::Core::Records::Draft
    def test_field_set_merge_deep_copies_right_hand_values
      right = { payload: { tags: ["first"] } }
      merged = Julewire::Core::Fields::FieldSet.merge({}, right)

      right[:payload][:tags] << "second"

      assert_equal ["first"], merged.dig(:payload, :tags)
    end

    def test_field_set_merge_bang_deep_copies_right_hand_values
      target = {}
      fields = { payload: { tags: ["first"] } }

      Julewire::Core::Fields::FieldSet.merge!(target, fields)
      fields[:payload][:tags] << "second"

      assert_equal ["first"], target.dig(:payload, :tags)
    end
  end
end
