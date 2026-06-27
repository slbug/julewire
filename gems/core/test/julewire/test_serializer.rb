# frozen_string_literal: true

require "test_helper"
require "bigdecimal"
require "date"
require "json"

module Julewire
  class TestSerializer < Minitest::Test
    cover "Julewire::Core::Serialization::EncodingSanitizer.call"
    cover "Julewire::Core::Serialization::BoundedTraversal#walk_container"
    cover Julewire::Core::Serialization
    cover Julewire::Core::Serialization::BacktraceLimiter
    cover Julewire::Core::Fields::FieldSet
    cover Julewire::Core::Records::Record
    cover Julewire::Core::Records::Draft
    cover "Julewire::Core::Serialization::Serializer#hash_like?"
    cover "Julewire::Core::Serialization::Serializer#serialize_temporal"
    cover "Julewire::Core::Serialization::Serializer#serialize_iso8601_temporal"
    def test_serializer_normalizes_top_level_scalar_types
      timestamp = Time.utc(2026, 5, 23, 12, 30, 1.123456)

      assert_equal "value", Julewire::Core::Serialization::Serializer.call(:value)
      assert_equal 42, Julewire::Core::Serialization::Serializer.call(42)
      assert_true Julewire::Core::Serialization::Serializer.call(true)
      assert_equal "2026-05-23T12:30:01.123456000Z", Julewire::Core::Serialization::Serializer.call(timestamp)
    end

    def test_serializer_duplicates_valid_utf8_strings
      value = +"value"
      serialized = Julewire::Core::Serialization::Serializer.call(value)

      value << "-changed"

      assert_equal "value", serialized
      refute_same value, serialized
    end

    def test_serializer_serializes_records_as_data
      record = build_record({ event: :created, payload: { id: 1 } }, context: {}, scope: nil)

      serialized = Julewire::Core::Serialization::Serializer.call(record)

      assert_equal "created", serialized.fetch("event")
      assert_equal({ "id" => 1 }, serialized.fetch("payload"))
    end

    def test_serializer_uses_records_record_namespace
      serializer = Julewire::Core::Serialization::Serializer
      serializer.const_set(:Record, Class.new)
      record = build_record({ event: :created, payload: { id: 1 } }, context: {}, scope: nil)

      serialized = serializer.call(record)

      assert_equal "created", serialized.fetch("event")
      assert_equal({ "id" => 1 }, serialized.fetch("payload"))
    ensure
      serializer.__send__(:remove_const, :Record) if serializer.const_defined?(:Record, false)
    end

    def test_serializer_uses_top_level_big_decimal_namespace
      serializer = Julewire::Core::Serialization::Serializer
      serializer.const_set(:BigDecimal, Class.new)

      serialized = serializer.call(BigDecimal("123.45"))

      assert_equal "123.45", serialized
    ensure
      serializer.__send__(:remove_const, :BigDecimal) if serializer.const_defined?(:BigDecimal, false)
    end

    def test_serializer_does_not_mutate_time_values
      timestamp = Time.new(2026, 5, 24, 12, 0, 0, "+02:00")

      serialized = Julewire::Core::Serialization::Serializer.call(timestamp)

      assert_equal "2026-05-24T10:00:00.000000000Z", serialized
      assert_equal 7200, timestamp.utc_offset
    end

    def test_serializer_accepts_datetime_subclasses
      datetime = Class.new(DateTime).new(2026, 5, 24, 10, 30, 15)

      serialized = Julewire::Core::Serialization::Serializer.call(datetime)

      assert_equal "2026-05-24T10:30:15.000000000+00:00", serialized
    end

    def test_serializer_clean_temporals_do_not_inherit_sibling_truncation_state
      values = {
        time: Time.utc(2026, 5, 24, 10, 0, 0),
        datetime: DateTime.new(2026, 5, 24, 10, 30, 15),
        date: Date.new(2026, 5, 24)
      }

      values.each do |key, temporal|
        serialized = Julewire::Core::Serialization::Serializer.call(
          { long: "abcd", key => temporal },
          max_string_bytes: 1
        )
        truncated_fields = serialized.fetch("_julewire_truncation").fetch("truncated_fields")

        assert_includes truncated_fields, "long"
        refute_includes truncated_fields, key.to_s
      end
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

    def test_serializer_uses_nine_digit_precision_for_zone_temporals
      time_with_zone = Class.new do
        def iso8601(*) = "local"

        def time_zone = "UTC"

        def utc
          Object.new.tap do |utc_time|
            utc_time.define_singleton_method(:iso8601) { |precision = nil| "precision=#{precision.inspect}" }
          end
        end
      end.new

      serialized = Julewire::Core::Serialization::Serializer.call(time_with_zone)

      assert_equal "precision=9", serialized
    end

    def test_serializer_sanitizes_zone_temporal_output
      time_with_zone = Class.new do
        def iso8601(*) = "local"

        def time_zone = "UTC"

        def utc
          Object.new.tap do |utc_time|
            utc_time.define_singleton_method(:iso8601) do |_precision = nil|
              invalid = +"bad\xFF"
              invalid.force_encoding(Encoding::UTF_8)
              invalid
            end
          end
        end
      end.new

      serialized = Julewire::Core::Serialization::Serializer.call(time_with_zone)

      assert_equal "bad?", serialized
    end

    def test_serializer_marks_broken_zone_temporals_as_unserializable
      broken_temporal = Class.new do
        def iso8601(*) = raise "broken temporal"

        def time_zone = "UTC"
      end.new

      serialized = Julewire::Core::Serialization::Serializer.call(broken_temporal)

      assert_equal "[Unserializable: RuntimeError]", serialized
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
      assert_true serialized.dig(1, "_julewire_truncation", "truncated")
      assert_includes serialized.dig(1, "_julewire_truncation", "truncated_fields"), "array_items"
    end

    def test_serializer_prunes_repeated_sibling_cyclic_references
      value = {}
      value[:first] = value
      value[:second] = value

      serialized = Julewire::Core::Serialization::Serializer.call(value)

      assert_equal "[Circular]", serialized["first"]
      assert_equal "[Circular]", serialized["second"]
      assert_true serialized.dig("_julewire_truncation", "truncated")
      assert_includes serialized.dig("_julewire_truncation", "truncated_fields"), "first"
      assert_includes serialized.dig("_julewire_truncation", "truncated_fields"), "second"
    end

    def test_serializer_serializes_repeated_sibling_containers_independently
      shared = { value: 1 }

      serialized = Julewire::Core::Serialization::Serializer.call({ first: shared, second: shared })

      assert_equal({ "value" => 1 }, serialized.fetch("first"))
      assert_equal({ "value" => 1 }, serialized.fetch("second"))
    end

    def test_serializer_tracks_active_containers_by_identity
      equal_hash = Class.new(Hash) do
        def hash = 1

        def eql?(_other) = true
      end
      child = equal_hash.new.merge!(value: 1)
      parent = equal_hash.new.merge!(child: child)

      serialized = Julewire::Core::Serialization::Serializer.call(parent)

      assert_equal({ "value" => 1 }, serialized.fetch("child"))
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
      assert_false serialized.key?("backtrace")
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

    def test_exception_shape_does_not_touch_backtrace_when_limit_is_zero
      error_class = Class.new(RuntimeError) do
        def backtrace
          raise SystemStackError, "backtrace should not be touched"
        end
      end

      shaped = Julewire::Core::Serialization::ExceptionShape.call(error_class.new("boom"), max_backtrace_lines: 0)

      assert_equal "boom", shaped.fetch(:message)
      refute_includes shaped, :backtrace
    end

    def test_exception_shape_truncates_causes_at_exact_configured_depth
      third = RuntimeError.new("third")
      second = exception_with_cause("second", third)
      first = exception_with_cause("first", second)
      root = exception_with_cause("root", first)

      shaped = Julewire::Core::Serialization::ExceptionShape.call(
        root,
        max_backtrace_lines: 0,
        max_cause_depth: 2
      )

      assert_equal "first", shaped.dig(:cause, :message)
      assert_equal "second", shaped.dig(:cause, :cause, :message)
      assert_true shaped.dig(:cause, :cause, :cause_truncated)
      refute_includes shaped.dig(:cause, :cause), :cause
    end

    def test_exception_shape_contains_non_exception_custom_cause
      error = Class.new(RuntimeError) do
        def cause = "string cause"
      end.new("boom")

      shaped = Julewire::Core::Serialization::ExceptionShape.call(error, max_backtrace_lines: 0)

      assert_equal "string cause", shaped.fetch(:cause)
    end

    def test_exception_shape_marks_circular_custom_cause
      error = Class.new(RuntimeError) do
        def cause = self
      end.new("boom")

      shaped = Julewire::Core::Serialization::ExceptionShape.call(error, max_backtrace_lines: 0)

      assert_equal Julewire::Core::CIRCULAR_REFERENCE, shaped.fetch(:cause)
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

    private

    def exception_with_cause(message, cause)
      raise cause
    rescue StandardError
      begin
        raise message.to_s
      rescue RuntimeError => error
        error
      end
    end
  end

  class TestSerializerStateAndDuckTypes < Minitest::Test
    cover "Julewire::Core::Serialization::EncodingSanitizer.call"
    cover Julewire::Core::Serialization
    cover Julewire::Core::Fields::FieldSet
    cover Julewire::Core::Records::Record
    cover Julewire::Core::Records::Draft
    cover "Julewire::Core::Serialization::Serializer#serialize_temporal"
    cover "Julewire::Core::Serialization::Serializer#serialize_iso8601_temporal"
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

      assert_true probe.active_during_each
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
end
