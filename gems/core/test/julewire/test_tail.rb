# frozen_string_literal: true

require "test_helper"
require "stringio"

module Julewire
  class TestTail < Minitest::Test
    cover Julewire::Tail
    cover Julewire::Core::Diagnostics::Tail
    class TtyStringIO < StringIO
      def tty? = true
    end

    class BlockingSerializer
      def initialize
        @delegate = Julewire::Core::Serialization::Serializer.new(compact_empty: true)
        @mutex = Mutex.new
        @entered = Queue.new
        @release = Queue.new
        @active = false
      end

      def serialize(payload)
        @mutex.synchronize do
          raise "serializer overlapped" if @active

          @active = true
        end
        @entered << true
        @release.pop
        @delegate.serialize(payload)
      ensure
        @mutex.synchronize { @active = false }
      end

      def release_one
        raise "serializer did not start" unless @entered.pop(timeout: 1)

        @release << true
      end
    end

    class ReturningSerializer
      def initialize(value)
        @value = value
      end

      def serialize(_payload) = @value
    end

    class CapturingSerializer
      attr_reader :payloads

      def initialize
        @payloads = []
      end

      def serialize(payload)
        @payloads << payload
        payload
      end
    end

    class ActiveSerializer
      def in_use? = true

      def serialize(_payload)
        raise "pooled serializer reused"
      end
    end

    class FallbackSerializer
      attr_reader :payloads

      def initialize
        @payloads = []
      end

      def serialize(payload)
        @payloads << payload
        { "message" => payload.fetch(:message) }
      end
    end

    class InactiveSerializer < FallbackSerializer
      def in_use? = false
    end

    class ReentrantTail < Julewire::Tail
      attr_reader :fallback_serializer

      def initialize(...)
        @active_serializer = ActiveSerializer.new
        @fallback_serializer = FallbackSerializer.new
        super
      end

      private

      def cached_serializer = @active_serializer

      def build_serializer = @fallback_serializer
    end

    class CacheHitTail < Julewire::Tail
      attr_reader :cached_serializer

      def initialize(...)
        @cached_serializer = InactiveSerializer.new
        super
      end

      private

      def build_serializer
        raise "fallback serializer should not be used"
      end
    end

    class CountingBuildTail < Julewire::Tail
      attr_reader :builds

      def initialize(...)
        @builds = 0
        super
      end

      private

      def build_serializer
        @builds += 1
        super
      end
    end

    class TailPayloadHash < Hash
    end

    class PayloadScopedSerializer
      def initialize(payload)
        @payload = payload
      end

      def in_use? = false

      def serialize(payload)
        raise "serializer pool leaked across tails" unless payload.equal?(@payload)

        payload
      end
    end

    class PoolScopedTail < Julewire::Tail
      def initialize(payload)
        @payload = payload
        super(formatter: ->(_record) { payload })
      end

      private

      def build_serializer = PayloadScopedSerializer.new(@payload)
    end

    def test_tail_attach_captures_bounded_records
      tail = Julewire.tail(capacity: 2)

      Julewire.info("first", event: "tail.first")
      Julewire.warn("second", event: "tail.second")
      Julewire.error("third", event: "tail.third")

      records = tail.records
      messages = records.map { it.fetch("message") }
      limited_messages = tail.records(limit: 1).map { it.fetch("message") }

      assert_equal 2, records.length
      assert_equal %w[second third], messages
      assert_equal ["third"], limited_messages
    end

    def test_tail_stores_public_record_projection
      tail = Julewire.tail

      Julewire.with_execution(type: :job, id: "job-1", emit_summary: false) do
        Julewire.carry.add(secret: "hidden")
        Julewire.error("third", event: "tail.third", account_id: "acct-1")
      end

      records = tail.records

      assert_equal "tail.third", records.last.fetch("event")
      assert_equal({ "account_id" => "acct-1" }, records.last.fetch("payload"))
      assert_false records.last.key?("carry")
      assert_false records.last.fetch("execution").key?("ancestors")
      assert_predicate records.last, :frozen?
    end

    def test_tail_render_and_write
      tail = Julewire.tail
      Julewire.error("boom", event: "tail.error", source: "test", account_id: "acct-1")

      rendered = tail.render
      io = StringIO.new

      assert_includes rendered, "ERROR"
      assert_includes rendered, "event=tail.error"
      assert_includes rendered, "source=test"
      assert_includes rendered, "boom"
      assert_includes rendered, "\"account_id\":\"acct-1\""
      assert_same io, tail.write(io, color: false)
      assert_equal rendered, io.string
    end

    def test_tail_write_defaults_to_stdout
      tail = Julewire.tail
      Julewire.error("boom", event: "tail.error")

      stdout, stderr = capture_io { assert_same $stdout, tail.write(color: false) }

      assert_empty stderr
      assert_includes stdout, "ERROR"
      assert_includes stdout, "event=tail.error"
    end

    def test_tail_write_forwards_limit_to_renderer
      tail = Julewire.tail
      Julewire.info("first", event: "tail.first")
      Julewire.error("second", event: "tail.second")
      io = StringIO.new

      tail.write(io, limit: 1, color: false)

      refute_includes io.string, "tail.first"
      assert_includes io.string, "tail.second"
    end

    def test_tail_write_uses_io_tty_for_default_color
      tail = Julewire.tail
      Julewire.error("boom", event: "tail.error")
      io = TtyStringIO.new

      tail.write(io)

      assert_includes io.string, "\e[31mERROR\e[0m"
    end

    def test_tail_write_defaults_to_plain_output_for_non_tty_io
      tail = Julewire.tail
      Julewire.error("boom", event: "tail.error")
      io = StringIO.new

      tail.write(io)

      refute_includes io.string, "\e["
      assert_includes io.string, "ERROR"
    end

    def test_tail_write_explicit_color_overrides_io_tty
      tail = Julewire.tail
      Julewire.error("boom", event: "tail.error")
      io = TtyStringIO.new

      tail.write(io, color: false)

      refute_includes io.string, "\e["
      assert_includes io.string, "ERROR"
    end

    def test_tail_write_explicit_color_overrides_non_tty_io
      tail = Julewire.tail
      Julewire.error("boom", event: "tail.error")
      io = StringIO.new

      tail.write(io, color: true)

      assert_includes io.string, "\e[31mERROR\e[0m"
    end

    def test_tail_attach_defaults_to_default_runtime
      tail = Julewire::Core::Diagnostics::Tail.attach!(capacity: 1)

      Julewire.info("captured", event: "tail.default")

      assert_instance_of Julewire::Core::Diagnostics::Tail, tail
      assert_equal(["tail.default"], tail.records.map { it.fetch("event") })
    end

    def test_tail_after_fork_returns_self
      tail = Julewire.tail
      Julewire.info("before-fork", event: "tail.before_fork")

      assert_same tail, tail.after_fork!
      assert_empty tail.records
    end

    def test_tail_renderer_truncates_long_values
      renderer = Julewire::Tail::Renderer.new(max_value_bytes: 8)
      entry = Julewire::Tail::Entry.new(
        1,
        Time.utc(2026, 6, 12, 10, 0, 0),
        {
          "severity" => "info",
          "event" => "tail.message",
          "message" => "abcdefghijklmnop"
        }
      )

      assert_includes renderer.call([entry]), "abcdefgh..."
    end

    def test_tail_renderer_uses_serialization_text_encoder
      renderer_class = Julewire::Core::Diagnostics::Tail::Renderer
      renderer = renderer_class.new
      encoder = Class.new do
        def initialize(*)
          raise "wrong text encoder"
        end
      end
      entry = Julewire::Tail::Entry.new(1, Time.utc(2026, 6, 12, 10, 0, 0), { "severity" => "info" })

      renderer_class.const_set(:TextEncoder, encoder)

      assert_equal "2026-06-12T10:00:00.000000Z INFO \n", renderer.call([entry])
    ensure
      renderer_class.__send__(:remove_const, :TextEncoder) if renderer_class.const_defined?(:TextEncoder, false)
    end

    def test_tail_renderer_handles_sparse_records
      renderer = Julewire::Tail::Renderer.new
      entry = Julewire::Tail::Entry.new(1, Time.utc(2026, 6, 12, 10, 0, 0), { "severity" => "debug" })

      assert_equal "2026-06-12T10:00:00.000000Z DEBUG\n", renderer.call([entry])
    end

    def test_tail_renderer_lets_text_encoder_format_fallback_timestamp
      renderer = Julewire::Tail::Renderer.new
      timestamp = Object.new
      def timestamp.iso8601(precision) = "stamp-#{precision}"
      def timestamp.to_s = "raw-object"
      entry = Julewire::Tail::Entry.new(1, timestamp, { "severity" => "debug" })

      assert_equal "stamp-6 DEBUG\n", renderer.call([entry])
    end

    def test_tail_renderer_preserves_record_timestamp
      renderer = Julewire::Tail::Renderer.new
      entry = Julewire::Tail::Entry.new(
        1,
        Time.utc(2026, 6, 12, 10, 0, 0),
        { "timestamp" => "2026-06-12T09:00:00Z", "severity" => "debug" }
      )

      assert_equal "2026-06-12T09:00:00Z DEBUG\n", renderer.call([entry])
    end

    def test_tail_derives_display_message_before_hiding_neutral
      tail = Julewire::Tail.new
      record = tail_request_summary_record

      tail.emit(record)

      snapshot = tail.records.fetch(0)
      expected = Julewire::Core::Records::DisplayMessage.call(record)

      assert_equal "GET /julewire_probe -> 500 RuntimeError in 273.828ms", expected
      assert_equal expected, snapshot.fetch("message")
      assert_false snapshot.key?("neutral")
      assert_includes tail.render, expected
    end

    def test_tail_keeps_non_hash_formatter_payloads
      tail = Julewire::Tail.new(formatter: ->(_record) { "plain payload" })

      tail.emit(build_record({ message: "ignored" }))

      assert_equal "plain payload", tail.records.fetch(0)
    end

    def test_tail_adds_display_message_to_empty_formatter_message
      tail = Julewire::Tail.new(formatter: ->(_record) { { "message" => "" } })

      tail.emit(tail_request_summary_record)

      assert_equal "GET /julewire_probe -> 500 RuntimeError in 273.828ms", tail.records.fetch(0).fetch("message")
    end

    def test_tail_preserves_non_string_scalar_formatter_message
      tail = Julewire::Tail.new(formatter: ->(_record) { { "message" => 42 } })

      tail.emit(tail_request_summary_record)

      assert_equal 42, tail.records.fetch(0).fetch("message")
    end

    def test_tail_preserves_existing_string_message_payload
      tail = Julewire::Tail.new(formatter: ->(_record) { { "message" => "formatter message" } })

      tail.emit(tail_request_summary_record)

      assert_equal "formatter message", tail.records.fetch(0).fetch("message")
    end

    def test_tail_preserves_existing_symbol_message_payload
      tail = Julewire::Tail.new(
        formatter: ->(_record) { :ignored },
        serializer: ReturningSerializer.new({ message: "serializer message" })
      )

      tail.emit(tail_request_summary_record)

      assert_equal "serializer message", tail.records.fetch(0).fetch(:message)
      refute_includes tail.records.fetch(0), "message"
    end

    def test_tail_adds_display_message_to_hash_subclass_payload
      tail = Julewire::Tail.new(
        formatter: ->(_record) { :ignored },
        serializer: ReturningSerializer.new(TailPayloadHash.new)
      )

      tail.emit(tail_request_summary_record)

      assert_equal "GET /julewire_probe -> 500 RuntimeError in 273.828ms", tail.records.fetch(0).fetch("message")
    end

    def test_tail_adds_display_message_to_frozen_payload_copy
      payload = {}.freeze
      tail = Julewire::Tail.new(
        formatter: ->(_record) { :ignored },
        serializer: ReturningSerializer.new(payload)
      )

      tail.emit(tail_request_summary_record)

      assert_equal "GET /julewire_probe -> 500 RuntimeError in 273.828ms", tail.records.fetch(0).fetch("message")
      refute_includes payload, "message"
    end

    def test_tail_leaves_payload_without_display_message_unchanged
      tail = Julewire::Tail.new(formatter: ->(_record) { {} })

      tail.emit(build_record({ message: nil, error: nil, metrics: {} }))

      assert_equal({}, tail.records.fetch(0))
    end

    def test_tail_forwards_formatter_payload_to_custom_serializer
      serializer = CapturingSerializer.new
      payload = "custom payload"
      tail = Julewire::Tail.new(formatter: ->(_record) { payload }, serializer: serializer)

      tail.emit(build_record({ message: "ignored" }))

      assert_equal [payload], serializer.payloads
      assert_equal payload, tail.records.fetch(0)
    end

    def test_tail_default_serializer_compacts_empty_formatter_payloads
      tail = Julewire::Tail.new(
        formatter: lambda { |_record|
          {
            message: "kept",
            empty_hash: {},
            empty_array: [],
            nested: { empty: nil, keep: "yes" },
            nil_value: nil
          }
        }
      )

      tail.emit(build_record({ message: "ignored" }))

      assert_equal(
        {
          "message" => "kept",
          "nested" => { "keep" => "yes" }
        },
        tail.records.fetch(0)
      )
    end

    def test_tail_default_serializer_is_cached_per_tail
      tail = CountingBuildTail.new(formatter: ->(_record) { { message: "cached payload" } })

      2.times { tail.emit(build_record({ message: "ignored" })) }

      assert_equal 1, tail.builds
      assert_equal(["cached payload", "cached payload"], tail.records.map { it.fetch("message") })
    end

    def test_tail_uses_fallback_serializer_when_cached_serializer_is_active
      tail = ReentrantTail.new(formatter: ->(_record) { { message: "fallback payload" } })

      tail.emit(build_record({ message: "ignored" }))

      assert_equal [{ message: "fallback payload" }], tail.fallback_serializer.payloads
      assert_equal "fallback payload", tail.records.fetch(0).fetch("message")
      assert_equal({ captured: 1, failures: 0 }, tail.health.fetch(:counts))
      assert_equal 1, tail.health.fetch(:size)
    end

    def test_tail_uses_cached_serializer_when_it_is_not_active
      tail = CacheHitTail.new(formatter: ->(_record) { { message: "cached payload" } })

      tail.emit(build_record({ message: "ignored" }))

      assert_equal [{ message: "cached payload" }], tail.cached_serializer.payloads
      assert_equal "cached payload", tail.records.fetch(0).fetch("message")
      assert_equal({ captured: 1, failures: 0 }, tail.health.fetch(:counts))
    end

    def test_tail_serializer_pool_is_scoped_per_tail
      unscoped_pool_key = :julewire_core_tail_serializers_
      previous_pool = Thread.current.thread_variable_get(unscoped_pool_key)
      Thread.current.thread_variable_set(unscoped_pool_key, nil)
      first_payload = { message: "first" }
      second_payload = { message: "second" }
      first = PoolScopedTail.new(first_payload)
      second = PoolScopedTail.new(second_payload)

      first.emit(build_record({ message: "ignored" }))
      second.emit(build_record({ message: "ignored" }))

      assert_equal [first_payload], first.records
      assert_equal [second_payload], second.records
      assert_equal({ captured: 1, failures: 0 }, first.health.fetch(:counts))
      assert_equal({ captured: 1, failures: 0 }, second.health.fetch(:counts))
    ensure
      Thread.current.thread_variable_set(unscoped_pool_key, previous_pool) if defined?(unscoped_pool_key)
    end

    def test_tail_entries_have_monotonic_sequence_and_utc_timestamps
      tail = Julewire::Tail.new

      assert_nil tail.emit(build_record({ message: "one" }))
      assert_nil tail.emit(build_record({ message: "two" }))

      entries = tail.entries

      assert_equal [1, 2], entries.map(&:sequence)
      assert_true(entries.all? { it.at.is_a?(Time) && it.at.utc? })
    end

    def test_tail_retains_every_concurrent_emit_with_unique_monotonic_sequence
      tail = Julewire::Tail.new(capacity: 16)
      start = Queue.new
      threads = Array.new(16) do |index|
        safe_thread do
          start.pop
          tail.emit(build_record({ message: "record-#{index}" }))
        end
      end

      16.times { start << true }
      safe_thread_values(threads)

      entries = tail.entries

      assert_equal (1..16).to_a, entries.map(&:sequence)
      assert_equal (0...16).map { "record-#{it}" }.sort, entries.map { it.record.fetch("message") }.sort
      assert_equal({ captured: 16, failures: 0 }, tail.health.fetch(:counts))
      assert_equal 16, tail.health.fetch(:size)
    ensure
      threads&.each { cleanup_thread(it) }
    end

    def test_tail_entries_returns_a_snapshot_copy
      tail = Julewire::Tail.new

      assert_nil tail.emit(build_record({ message: "one" }))

      entries = tail.entries
      entries.clear

      assert_equal 1, tail.entries.length
      assert_equal "one", tail.records.fetch(0).fetch("message")
    end

    def tail_request_summary_record
      Julewire::Core::Records::Draft.build(
        {
          error: RuntimeError.new("123"),
          event: "request.completed",
          metrics: { duration_ms: 273.828 },
          severity: :error
        },
        carry: {},
        context: {},
        neutral: {
          Julewire::Core::Fields::AttributeKeys::HTTP_REQUEST_METHOD => "GET",
          Julewire::Core::Fields::AttributeKeys::HTTP_RESPONSE_STATUS_CODE => 500,
          Julewire::Core::Fields::AttributeKeys::URL_PATH => "/julewire_probe"
        },
        scope: nil
      ).to_record
    end

    def test_tail_records_formatter_failures_in_health
      formatter = ->(_record) { raise "format failed" }
      tail = Julewire::Tail.new(formatter: formatter)

      assert_nil tail.emit(build_record({ event: "tail.hidden", message: "hidden", severity: :warn }))

      health = tail.health

      assert_equal :degraded, health.fetch(:status)
      assert_equal tail.capacity, health.fetch(:capacity)
      assert_equal 1, health.dig(:counts, :failures)
      assert_equal "RuntimeError", health.dig(:last_failure, :class)
      assert_equal :emit, health.dig(:last_failure, :action)
      assert_equal :tail, health.dig(:last_failure, :destination)
      assert_equal :tail, health.dig(:last_failure, :phase)
      assert_equal "tail.hidden", health.dig(:last_failure, :record, :event)
      assert_equal :warn, health.dig(:last_failure, :record, :severity)
    end

    def test_tail_records_nil_formatter_output_as_failure
      tail = Julewire::Tail.new(formatter: ->(_record) {})

      tail.emit(build_record({ message: "hidden" }))

      assert_equal :degraded, tail.health.fetch(:status)
      assert_equal "TypeError", tail.health.dig(:last_failure, :class)
    end

    def test_tail_nil_formatter_error_message_is_diagnostic
      tail = Julewire::Tail.new(formatter: ->(_record) {})

      error = assert_raises(TypeError) { tail.send(:snapshot_record, build_record({ message: "hidden" })) }

      assert_equal "formatter must return a payload object", error.message
    end

    def test_tail_serializes_custom_serializer_access_across_threads
      serializer = BlockingSerializer.new
      tail = Julewire::Tail.new(serializer: serializer)
      threads = Array.new(2) do |index|
        safe_thread { tail.emit(build_record({ message: "record-#{index}" })) }
      end

      2.times { serializer.release_one }
      safe_thread_values(threads)

      assert_equal({ captured: 2, failures: 0 }, tail.health.fetch(:counts))
    end

    def test_tail_validates_options
      assert_raises_message(ArgumentError, /name must be/) { Julewire::Tail.new(name: Object.new) }
      assert_raises_message(ArgumentError, /capacity must/) { Julewire::Tail.new(capacity: 0) }
      assert_raises_message(ArgumentError, /max_value_bytes must/) { Julewire::Tail::Renderer.new(max_value_bytes: 0) }
      assert_raises_message(ArgumentError, "formatter must respond to #call") { Julewire::Tail.new(formatter: Object.new) }
      assert_raises_message(ArgumentError, "renderer must respond to #call") { Julewire::Tail.new(renderer: Object.new) }

      tail = Julewire::Tail.new
      assert_raises_message(ArgumentError, /limit must/) { tail.records(limit: 0) }
    end

    def test_tail_clear_and_after_fork_reset_entries
      tail = Julewire.tail
      Julewire.info("one")

      assert_equal 1, tail.records.length

      assert_same tail, tail.clear
      assert_empty tail.records

      Julewire.info("two")
      tail.after_fork!

      assert_empty tail.records
      assert_equal({ captured: 0, failures: 0 }, tail.health.fetch(:counts))
    end

    def test_tail_clear_resets_degradation_and_lifecycle_returns_self
      tail = Julewire::Tail.new(formatter: ->(_record) { raise "format failed" })

      tail.emit(build_record({ message: "hidden" }))

      assert_equal :degraded, tail.health.fetch(:status)
      assert_same tail, tail.clear
      assert_equal :ok, tail.health.fetch(:status)
      assert_nil tail.health[:last_failure]
      assert_same tail, tail.flush
      assert_same tail, tail.close
    end
  end
end
