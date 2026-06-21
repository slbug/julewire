# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestLogger < Minitest::Test
    cover Julewire::Rails::Logger

    def test_that_it_has_a_version_number
      refute_nil ::Julewire::Rails::VERSION
    end

    def test_logger_emits_string_messages
      output = configure_output
      logger = Julewire::Rails::Logger.new(name: "Rails")

      logger.info("booted")

      record = parse_records(output).fetch(0)

      assert_equal "info", record.fetch("severity")
      assert_equal "rails", record.fetch("source")
      assert_equal "Rails", record.fetch("logger")
      assert_equal "booted", record.fetch("message")
      assert_julewire_record_source_contract(
        records: [record],
        event: "log",
        source: "rails",
        logger: "Rails",
        kind: "point"
      )
    end

    def test_logger_moves_unknown_hash_keys_into_payload
      output = configure_output
      logger = Julewire::Rails::Logger.new(name: "Rails")

      logger.warn(message: "retrying", event: "payment.retry", payment_id: 123, kind: "summary", execution: { id: "x" })

      record = parse_records(output).fetch(0)

      assert_equal "warn", record.fetch("severity")
      assert_equal "payment.retry", record.fetch("event")
      assert_equal "retrying", record.fetch("message")
      assert_equal 123, record.dig("payload", "payment_id")
      assert_equal "summary", record.dig("payload", "kind")
      assert_equal({ "id" => "x" }, record.dig("payload", "execution"))
      assert_equal "point", record.fetch("kind")
    end

    def test_logger_payload_partition_tracks_field_bags
      output = configure_output
      logger = Julewire::Rails::Logger.new(name: "Rails")

      logger.warn(logger_field_bag_probe.merge(extra: "payload"))

      payload = parse_records(output).fetch(0).fetch("payload")
      forged = %w[kind execution carry attributes neutral]
      record_keys = Julewire::Core::Fields::Bags.required_record_keys.map(&:to_s)

      assert_equal "payload", payload.fetch("extra")
      assert_equal forged.sort, (payload.keys & forged).sort
      assert_empty(payload.keys & (record_keys - forged - %w[payload]))
    end

    def test_logger_preserves_active_support_tags_as_rails_attributes
      output = configure_output
      logger = ActiveSupport::TaggedLogging.new(Julewire::Rails::Logger.new(name: "Rails"))

      logger.tagged("request-1") { logger.info("inside") }

      record = parse_records(output).fetch(0)

      assert_equal ["request-1"], record.dig("attributes", "rails", "tags")
    end

    def test_logger_silence_raises_temporary_threshold
      output = configure_output
      logger = Julewire::Rails::Logger.new(name: "Rails")

      logger.silence(Logger::ERROR) do
        logger.info("hidden")
        logger.error("visible")
      end

      records = parse_records(output)

      assert_equal 1, records.size
      assert_equal "visible", records.fetch(0).fetch("message")
    end

    def test_logger_records_that_pass_rails_level_skip_core_level_gate
      output = StringIO.new
      Julewire.configure do |config|
        config.level = :fatal
        configure_destination(config, output: output)
      end
      logger = Julewire::Rails::Logger.new(name: "Rails")
      logger.level = :info

      logger.info("rails-visible")
      Julewire.info(message: "core-hidden")

      records = parse_records(output)

      messages = records.map { it.fetch("message") }

      assert_equal ["rails-visible"], messages
    end

    def test_logger_close_does_not_close_global_julewire_runtime
      output = configure_output
      logger = Julewire::Rails::Logger.new(name: "Rails")

      logger.close
      logger.info("after close")

      record = parse_records(output).fetch(0)

      assert_equal "after close", record.fetch("message")
      refute_equal :closed, Julewire.health.fetch(:status)
    end

    def test_logger_handles_exception_messages_payload_shapes_and_thresholds
      output = configure_output
      logger = Julewire::Rails::Logger.new(name: "Rails", source: "custom")

      logger.level = :warn

      assert logger.add(Logger::INFO, "hidden")
      logger << "unknown line"
      logger.error(RuntimeError.new("boom"))
      logger.warn(message: "structured", payload: "value", extra: 1)
      logger.info!
      logger.info(nil) { "from block" }
      logger.info(nil)

      messages = parse_records(output).map { it.fetch("message") }

      assert_includes messages, "unknown line"
      assert_includes messages, "RuntimeError: boom"
      assert_includes messages, "structured"
      assert_includes messages, "from block"
      assert_includes messages, ""
      assert_includes parse_records(output).map { it.fetch("logger") }, "Rails"
      assert_equal "custom", parse_records(output).first.fetch("source")
    end

    def test_logger_rejects_invalid_levels_and_copies_progname
      logger = Julewire::Rails::Logger.new(name: +"Rails")

      assert_raises(ArgumentError) { logger.level = :invalid }
      assert_raises(ArgumentError) { logger.level = Object.new }

      copy = logger.dup

      refute_same logger.progname, copy.progname
      assert_equal "Rails", copy.progname
    end

    def test_logger_flush_clears_formatter_tags_when_supported
      formatter = Object.new
      cleared = false
      formatter.define_singleton_method(:clear_tags!) { cleared = true }
      logger = Julewire::Rails::Logger.new
      logger.formatter = formatter

      logger.flush

      assert cleared
    end

    def test_logger_supports_datetime_format_and_reopen_methods
      logger = Julewire::Rails::Logger.new

      logger.datetime_format = "%H:%M"

      assert_equal "%H:%M", logger.datetime_format
      assert logger.reopen
    end

    def test_logger_covers_structured_payload_and_tag_edges
      output = configure_output
      formatter = Object.new
      formatter.define_singleton_method(:current_tags) { ["tag-1"] }
      logger = Julewire::Rails::Logger.new(name: "Rails")
      logger.formatter = formatter

      logger.warn(message: "hash payload", payload: { existing: true }, extra: 1, tags: { explicit: true })
      logger.warn(message: "nil payload", extra: 2)
      logger.flush

      records = parse_records(output)

      assert records.fetch(0).dig("payload", "existing")
      assert_equal 1, records.fetch(0).dig("payload", "extra")
      assert records.fetch(0).dig("payload", "tags", "explicit")
      assert_equal ["tag-1"], records.fetch(0).dig("attributes", "rails", "tags")
      assert_equal 2, records.fetch(1).dig("payload", "extra")
    end

    def test_logger_handles_formatter_without_tag_helpers_and_non_string_progname_copy
      output = configure_output
      progname = Object.new
      logger = Julewire::Rails::Logger.new(name: progname)
      logger.formatter = Object.new

      copy = logger.dup
      logger.info("plain")
      logger.flush

      assert_same progname, copy.progname
      assert_equal "plain", parse_records(output).fetch(0).fetch("message")
    end

    private

    def logger_field_bag_probe
      {
        timestamp: Time.utc(2026, 1, 1),
        severity: :fatal,
        kind: "summary",
        event: "bag.event",
        message: "bag message",
        logger: "BagLogger",
        source: "bag-source",
        execution: { id: "fake" },
        context: { request_id: "ctx" },
        carry: { trace: "carry" },
        neutral: { "http.request.method": "GET" },
        attributes: { app: { shard: "a" } },
        labels: { route: "worker" },
        payload: { own: "payload" },
        metrics: { count: 1 },
        error: RuntimeError.new("boom")
      }
    end
  end
end
