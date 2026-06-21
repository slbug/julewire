# frozen_string_literal: true

require "test_helper"
require "date"
require "json"

module Julewire
  class TestSerializationAndErrors < Minitest::Test
    cover Julewire::Core::Serialization::JsonEncoder
    cover Julewire::Core::Serialization::Serializer
    cover Julewire::Core::Serialization::ValueCopy

    def test_serializer_normalizes_top_level_scalar_types
      timestamp = Time.utc(2026, 5, 23, 12, 30, 1.123456)

      assert_equal "value", Julewire::Core::Serialization::Serializer.call(:value)
      assert_equal 42, Julewire::Core::Serialization::Serializer.call(42)
      assert Julewire::Core::Serialization::Serializer.call(true)
      assert_equal "2026-05-23T12:30:01.123456000Z", Julewire::Core::Serialization::Serializer.call(timestamp)
    end

    def test_serializer_duplicates_valid_utf8_strings
      value = +"value"
      serialized = Julewire::Core::Serialization::Serializer.call(value)

      value << "-changed"

      assert_equal "value", serialized
      refute_same value, serialized
    end

    def test_json_encoder_serializes_mutable_strings_without_mutating_them
      value = +"value"
      encoded = Julewire::Core::Serialization::JsonEncoder.new.call({ message: value })

      value << "-changed"

      assert_equal({ "message" => "value" }, JSON.parse(encoded))
      assert_equal "value-changed", value
    end

    def test_json_encoder_keeps_serializer_cache_thread_local
      encoder = Julewire::Core::Serialization::JsonEncoder.new
      thread = Thread.new do
        encoder.call(message: "hello")
        Thread.current.thread_variable_get(:julewire_core_json_encoder_serializers).size
      end

      assert_equal 1, thread.value
      refute encoder.instance_variable_defined?(:@serializers)
    end

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

    def test_serializer_serializes_records_as_data
      record = build_record({ event: :created, payload: { id: 1 } }, context: {}, scope: nil)

      serialized = Julewire::Core::Serialization::Serializer.call(record)

      assert_equal "created", serialized.fetch("event")
      assert_equal({ "id" => 1 }, serialized.fetch("payload"))
    end

    def test_serializer_does_not_deep_copy_record_before_serializing
      record = build_record({ event: :created, payload: { id: 1 } }, context: {}, scope: nil)

      with_overridden_record_to_h do
        serialized = Julewire::Core::Serialization::Serializer.call(record)

        assert_equal "created", serialized.fetch("event")
        assert_equal({ "id" => 1 }, serialized.fetch("payload"))
      end
    end

    def test_record_prunes_cycles
      source = {}
      source[:payload] = source

      record = build_record(source, context: {}, scope: nil)

      assert_equal "[Circular]", record.dig(:payload, :value)
      refute_predicate source, :frozen?
    end

    def with_overridden_record_to_h
      record_class = Julewire::Core::Records::Record
      original = record_class.instance_method(:to_h)
      verbose = $VERBOSE
      $VERBOSE = nil
      record_class.define_method(:to_h) { raise "unexpected record copy" }
      yield
    ensure
      $VERBOSE = nil
      record_class.define_method(:to_h, original)
      $VERBOSE = verbose
    end

    def test_serializer_does_not_mutate_time_values
      timestamp = Time.new(2026, 5, 24, 12, 0, 0, "+02:00")

      serialized = Julewire::Core::Serialization::Serializer.call(timestamp)

      assert_equal "2026-05-24T10:00:00.000000000Z", serialized
      assert_equal 7200, timestamp.utc_offset
    end

    def test_serializer_normalizes_common_temporal_types
      date = Date.new(2026, 5, 24)
      datetime = DateTime.new(2026, 5, 24, 10, 30, 15)
      time_with_zone = Class.new do
        class << self
          def name = "TemporalWithZone"
        end

        def iso8601(_precision = nil) = "2026-05-24T12:30:15.000000000+02:00"

        def time_zone = "UTC"

        def utc
          Object.new.tap do |utc_time|
            utc_time.define_singleton_method(:iso8601) { |_precision = nil| "2026-05-24T10:30:15.000000000Z" }
          end
        end
      end.new

      serialized = Julewire::Core::Serialization::Serializer.call(
        {
          date: date,
          datetime: datetime,
          time_with_zone: time_with_zone
        }
      )

      assert_equal "2026-05-24", serialized["date"]
      assert_equal "2026-05-24T10:30:15.000000000+00:00", serialized["datetime"]
      assert_equal "2026-05-24T10:30:15.000000000Z", serialized["time_with_zone"]
    end

    def test_serializer_normalizes_non_finite_floats
      values = {
        finite: 12.25,
        nan: Float::NAN,
        positive_infinity: Float::INFINITY,
        negative_infinity: -Float::INFINITY
      }
      serialized = Julewire::Core::Serialization::Serializer.call(values)

      assert_in_delta 12.25, serialized["finite"]
      assert_equal "NaN", serialized["nan"]
      assert_equal "Infinity", serialized["positive_infinity"]
      assert_equal "-Infinity", serialized["negative_infinity"]
    end

    def test_serializer_normalizes_top_level_arrays
      serialized = Julewire::Core::Serialization::Serializer.call([:value, Time.utc(2026, 1, 1), 1])

      assert_equal ["value", "2026-01-01T00:00:00.000000000Z", 1], serialized
    end

    def test_serializer_prunes_self_referencing_arrays
      values = []
      values << values

      serialized = Julewire::Core::Serialization::Serializer.call(values)

      assert_equal "[Circular]", serialized.first
      assert serialized.dig(1, "_julewire_truncation", "truncated")
      assert_includes serialized.dig(1, "_julewire_truncation", "truncated_fields"), "array_items"
    end

    def test_serializer_prunes_repeated_sibling_cyclic_references
      value = {}
      value[:first] = value
      value[:second] = value

      serialized = Julewire::Core::Serialization::Serializer.call(value)

      assert_equal "[Circular]", serialized["first"]
      assert_equal "[Circular]", serialized["second"]
      assert serialized.dig("_julewire_truncation", "truncated")
      assert_includes serialized.dig("_julewire_truncation", "truncated_fields"), "first"
      assert_includes serialized.dig("_julewire_truncation", "truncated_fields"), "second"
    end

    def test_serializer_keeps_parent_marked_after_circular_reference
      value = {}
      value[:self] = value
      value[:child] = { parent: value }

      serialized = Julewire::Core::Serialization::Serializer.call(value)

      assert_equal "[Circular]", serialized["self"]
      assert_equal "[Circular]", serialized.dig("child", "parent")
    end

    def test_serializer_handles_exception_without_backtrace
      serialized = Julewire::Core::Serialization::Serializer.call(RuntimeError.new("boom"))

      assert_equal "RuntimeError", serialized["class"]
      assert_equal "boom", serialized["message"]
      refute serialized.key?("backtrace")
    end

    def test_serializer_caps_exception_backtrace
      error = RuntimeError.new("boom")
      error.set_backtrace(Array.new(30) { |index| "app.rb:#{index}" })

      serialized = Julewire::Core::Serialization::Serializer.call(error)

      assert_equal 20, serialized["backtrace"].length
      assert_equal "app.rb:19", serialized["backtrace"].last
    end

    def test_serializer_omits_exception_backtrace_when_limit_is_zero
      error = RuntimeError.new("boom")
      error.set_backtrace(["app.rb:1"])

      serialized = Julewire::Core::Serialization::Serializer.call(error, max_backtrace_lines: 0)

      refute_includes serialized, "backtrace"
    end

    def test_serializer_uses_bounded_object_fallback_without_inspect
      object = Object.new
      def object.inspect
        "secret-token"
      end

      serialized = Julewire::Core::Serialization::Serializer.call(object)

      assert_equal "[Object: Object]", serialized
      refute_includes serialized, "secret-token"
    end

    def test_serializer_repairs_invalid_utf8_strings
      assert_invalid_utf8_repaired do |value|
        Julewire::Core::Serialization::Serializer.call(value)
      end
    end

    def test_serializer_handles_large_hashes
      serialized = Julewire::Core::Serialization::Serializer.call(Array.new(200) { [it, it] }.to_h)

      assert_equal 200, serialized.length
      assert_equal 199, serialized["199"]
    end

    def test_serializer_ignores_broken_inspect
      object = Object.new
      def object.inspect
        raise "broken"
      end

      assert_equal "[Object: Object]", Julewire::Core::Serialization::Serializer.call(object)
    end

    def test_serializer_uses_generic_object_marker_for_anonymous_classes
      object = Class.new.new

      assert_equal "[Object]", Julewire::Core::Serialization::Serializer.call(object)
    end

    def test_serializer_cleans_seen_state_after_container_failure
      broken_array = Class.new(Array) do
        attr_writer :broken

        def each(&)
          raise "broken" if @broken

          super
        end
      end.new
      serializer = Julewire::Core::Serialization::Serializer.new(max_depth: 8)

      broken_array.broken = true

      assert_equal "[Unserializable: RuntimeError]", serializer.serialize(broken_array)

      broken_array.broken = false

      assert_equal [], serializer.serialize(broken_array)
    end
  end

  class TestSerializerStateAndDuckTypes < Minitest::Test
    cover Julewire::Core::Serialization::Serializer

    def test_serializer_can_skip_mutable_string_copies_for_encoder_reuse
      value = +"value"
      serializer = Julewire::Core::Serialization::Serializer.new(copy_strings: false)

      serialized = serializer.serialize(value)

      assert_same value, serialized
    end

    def test_serializer_reuses_frozen_strings
      value = +"value"
      value.freeze

      assert_same value, Julewire::Core::Serialization::Serializer.new.serialize(value)
    end

    def test_serializer_reports_active_state_only_during_serialization
      serializer = Julewire::Core::Serialization::Serializer.new
      probe = Class.new(Hash) do
        attr_accessor :serializer, :active_during_each

        def each(&)
          self.active_during_each = serializer.in_use?
          super
        end
      end[message: "hello"]
      probe.serializer = serializer

      serializer.serialize(probe)

      assert probe.active_during_each
      refute_predicate serializer, :in_use?
    end

    def test_serializer_requires_time_zone_duck_types_to_look_like_zone_temporals
      time_zone_only = Class.new do
        def time_zone = "UTC"
      end.new
      iso8601_only = Class.new do
        def iso8601(_precision = nil) = "2026-05-24T10:30:15.000000000Z"
      end.new

      serialized = Julewire::Core::Serialization::Serializer.call(
        {
          time_zone_only: time_zone_only,
          iso8601_only: iso8601_only
        }
      )

      assert_match(/\A\[Object/, serialized.fetch("time_zone_only"))
      assert_match(/\A\[Object/, serialized.fetch("iso8601_only"))
    end

    def test_serializer_handles_broken_temporal_detection_as_plain_object
      object = Class.new do
        def respond_to?(*)
          raise "broken respond_to?"
        end
      end.new

      assert_equal "[Object]", Julewire::Core::Serialization::Serializer.call(object)
    end

    def test_serializer_serializes_temporal_duck_without_utc
      time_with_zone = Class.new do
        def iso8601(_precision = nil) = "2026-05-24T12:30:15.000000000+02:00"

        def time_zone = "Warsaw"
      end.new

      assert_equal(
        "2026-05-24T12:30:15.000000000+02:00",
        Julewire::Core::Serialization::Serializer.call(time_with_zone)
      )
    end

    def test_serializer_serializes_time_subclasses_as_times
      time_subclass = Class.new(Time).new(2026, 5, 24, 12, 0, 0, "+02:00")

      assert_equal(
        "2026-05-24T10:00:00.000000000Z",
        Julewire::Core::Serialization::Serializer.call(time_subclass)
      )
    end

    def test_serializer_uses_generic_object_marker_for_empty_class_names
      klass = Class.new
      def klass.name = ""

      assert_equal "[Object]", Julewire::Core::Serialization::Serializer.call(klass.new)
    end

    def test_serializer_repairs_object_marker_class_names
      klass = Class.new
      def klass.name = "Broken\xFF".b

      assert_equal "[Object: Broken?]", Julewire::Core::Serialization::Serializer.call(klass.new)
    end

    def test_serializer_uses_generic_unserializable_marker_for_anonymous_errors
      error_class = Class.new(StandardError)
      broken_hash = {}
      broken_hash.define_singleton_method(:each) { raise error_class, "hidden" }

      assert_equal "[Unserializable]", Julewire::Core::Serialization::Serializer.call(broken_hash)
    end

    def test_serializer_uses_generic_unserializable_marker_for_empty_error_class_names
      error_class = Class.new(StandardError)
      def error_class.name = ""

      broken_hash = {}
      broken_hash.define_singleton_method(:each) { raise error_class, "hidden" }

      assert_equal "[Unserializable]", Julewire::Core::Serialization::Serializer.call(broken_hash)
    end

    def test_serializer_repairs_unserializable_marker_class_names
      error_class = Class.new(StandardError)
      def error_class.name = "Broken\xFF".b

      broken_hash = {}
      broken_hash.define_singleton_method(:each) { raise error_class, "hidden" }

      assert_equal "[Unserializable: Broken?]", Julewire::Core::Serialization::Serializer.call(broken_hash)
    end

    def test_serializer_uses_primitive_key_strings
      serialized = Julewire::Core::Serialization::Serializer.call(
        {
          nil => "nil",
          true => "true",
          false => "false",
          1 => "one"
        }
      )

      assert_equal "nil", serialized.fetch("")
      assert_equal "true", serialized.fetch("true")
      assert_equal "false", serialized.fetch("false")
      assert_equal "one", serialized.fetch("1")
    end

    def test_serializer_serializes_record_subclasses_as_record_data
      record = build_record({ event: :created, payload: { id: 1 } }, context: {}, scope: nil)
      subclass = Class.new(Julewire::Core::Records::Record)
      subclass_record = subclass.new(record.serializable_data, lineage: record.lineage)

      serialized = Julewire::Core::Serialization::Serializer.call(subclass_record)

      assert_equal "created", serialized.fetch("event")
      assert_equal({ "id" => 1 }, serialized.fetch("payload"))
    end
  end

  class TestRecordAndFieldSetHardening < Minitest::Test
    cover Julewire::Core::Fields::FieldSet
    cover Julewire::Core::Serialization::ValueCopy

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
      assert Ractor.shareable?(copy)
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

    def test_field_set_value_for_does_not_symbolize_unknown_key_objects
      key = Object.new

      def key.to_sym
        raise "should not symbolize"
      end

      assert_nil Julewire::Core::Fields::FieldSet.value_for({ safe: 1 }, key)
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

  class TestEncodingSanitizer < Minitest::Test
    def test_returns_valid_utf8_strings_as_is
      value = +"token"

      assert_same value, Julewire::Core::Serialization::EncodingSanitizer.call(value)
    end

    def test_transcodes_non_utf8_strings
      value = +"caf\xE9"
      value.force_encoding(Encoding::ISO_8859_1)

      sanitized = Julewire::Core::Serialization::EncodingSanitizer.call(value)

      assert_equal "café", sanitized
      assert_equal Encoding::UTF_8, sanitized.encoding
    end

    def test_returns_valid_ascii_only_strings_as_is
      value = +"2026-01-01T00:00:00Z"
      value.force_encoding(Encoding::US_ASCII)

      assert_same value, Julewire::Core::Serialization::EncodingSanitizer.call(value)
    end

    def test_scrubs_invalid_utf8_strings
      assert_invalid_utf8_repaired do |value|
        Julewire::Core::Serialization::EncodingSanitizer.call(value)
      end
    end

    def test_rejects_non_string_values
      assert_raises_message(TypeError, "value must be a String") do
        Julewire::Core::Serialization::EncodingSanitizer.call(Object.new)
      end
    end

    def test_rescue_path_repairs_invalid_bytes
      value = +"token \xE9"
      value.force_encoding(Encoding::ISO_8859_1)

      def value.encode(*)
        raise EncodingError, "broken"
      end

      def value.b
        +"token \xFF"
      end

      sanitized = Julewire::Core::Serialization::EncodingSanitizer.call(value)

      assert_equal "token ?", sanitized
      assert_predicate sanitized, :valid_encoding?
    end
  end

  class TestFieldSetPublicApi < Minitest::Test
    cover Julewire::Core::Fields::FieldSet

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
