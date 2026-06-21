# frozen_string_literal: true

require "test_helper"
require "stringio"

module Julewire
  class TestTail < Minitest::Test
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
      refute records.last.key?("carry")
      refute records.last.fetch("execution").key?("ancestors")
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

    def test_tail_write_uses_io_tty_for_default_color
      tail = Julewire.tail
      Julewire.error("boom", event: "tail.error")
      io = TtyStringIO.new

      tail.write(io)

      assert_includes io.string, "\e[31mERROR\e[0m"
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

    def test_tail_renderer_handles_sparse_records
      renderer = Julewire::Tail::Renderer.new
      entry = Julewire::Tail::Entry.new(1, Time.utc(2026, 6, 12, 10, 0, 0), { "severity" => "debug" })

      assert_equal "2026-06-12T10:00:00.000000Z DEBUG\n", renderer.call([entry])
    end

    def test_tail_derives_display_message_before_hiding_neutral
      tail = Julewire::Tail.new
      record = tail_request_summary_record

      tail.emit(record)

      snapshot = tail.records.fetch(0)
      expected = Julewire::Core::Records::DisplayMessage.call(record)

      assert_equal "GET /julewire_probe -> 500 RuntimeError in 273.828ms", expected
      assert_equal expected, snapshot.fetch("message")
      refute snapshot.key?("neutral")
      assert_includes tail.render, expected
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

      tail.emit(build_record({ message: "hidden" }))

      health = tail.health

      assert_equal :degraded, health.fetch(:status)
      assert_equal 1, health.dig(:counts, :failures)
      assert_equal "RuntimeError", health.dig(:last_failure, :class)
      assert_equal :tail, health.dig(:last_failure, :phase)
    end

    def test_tail_records_nil_formatter_output_as_failure
      tail = Julewire::Tail.new(formatter: ->(_record) {})

      tail.emit(build_record({ message: "hidden" }))

      assert_equal :degraded, tail.health.fetch(:status)
      assert_equal "TypeError", tail.health.dig(:last_failure, :class)
    end

    def test_tail_serializes_custom_serializer_access_across_threads
      serializer = BlockingSerializer.new
      tail = Julewire::Tail.new(serializer: serializer)
      threads = Array.new(2) do |index|
        Thread.new { tail.emit(build_record({ message: "record-#{index}" })) }
      end

      2.times { serializer.release_one }
      threads.each(&:join)

      assert_equal({ captured: 2, failures: 0 }, tail.health.fetch(:counts))
    end

    def test_tail_validates_options
      assert_raises_message(ArgumentError, /name must be/) { Julewire::Tail.new(name: Object.new) }
      assert_raises_message(ArgumentError, /capacity must/) { Julewire::Tail.new(capacity: 0) }

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
  end
end
