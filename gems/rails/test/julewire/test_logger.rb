# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestLogger < Minitest::Test
    cover Julewire::Rails::Logger
    cover Julewire::Rails::Suppression
    def test_logger_emits_string_messages
      output = configure_output
      logger = Julewire::Rails::Logger.new(name: "Rails")

      logger.info("booted")

      record = parse_records(output).fetch(0)

      assert_equal "info", record.fetch("severity")
      assert_equal "rails", record.fetch("source")
      assert_equal "Rails", record.fetch("logger")
      assert_equal "booted", record.fetch("message")
      assert_equal "log", record.fetch("event")
      assert_equal "point", record.fetch("kind")
    end

    def test_logger_treats_array_messages_as_scalar_messages
      output = configure_output
      logger = Julewire::Rails::Logger.new(name: "Rails")
      message = %w[first second]

      logger.info(message)

      record = parse_records(output).fetch(0)

      assert_equal message.to_s, record.fetch("message")
      assert_equal "Rails", record.fetch("logger")
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

    def test_logger_ignores_empty_current_tags
      captured = []
      output = configure_output(captured: captured)
      formatter = Object.new
      formatter.define_singleton_method(:current_tags) { [] }
      logger = Julewire::Rails::Logger.new(name: "Rails")
      logger.formatter = formatter

      logger.info("plain")

      record = parse_records(output).fetch(0)

      assert_nil captured.fetch(0).to_h.dig(:attributes, :rails)
      assert_false record.key?("attributes")
    end

    def test_logger_keeps_forged_attributes_in_payload_when_merging_current_tags
      output = configure_output
      formatter = Object.new
      formatter.define_singleton_method(:current_tags) { ["request-1"] }
      logger = Julewire::Rails::Logger.new(name: "Rails")
      logger.formatter = formatter

      logger.info(
        message: "inside",
        attributes: {
          app: { shard: "a" },
          rails: { controller: "HomeController" }
        }
      )

      record = parse_records(output).fetch(0)

      assert_equal "a", record.dig("payload", "attributes", "app", "shard")
      assert_equal "HomeController", record.dig("payload", "attributes", "rails", "controller")
      assert_equal ["request-1"], record.dig("attributes", "rails", "tags")
    end

    def test_logger_replaces_non_hash_attributes_when_merging_current_tags
      output = configure_output
      formatter = Object.new
      formatter.define_singleton_method(:current_tags) { ["request-1"] }
      logger = Julewire::Rails::Logger.new(name: "Rails")
      logger.formatter = formatter

      logger.info(message: "inside", attributes: "bad")

      record = parse_records(output).fetch(0)

      assert_equal({ "rails" => { "tags" => ["request-1"] } }, record.fetch("attributes"))
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

    def test_logger_public_level_predicates_and_bang_setters
      logger = Julewire::Rails::Logger.new

      logger.warn!

      refute_predicate logger, :debug?
      refute_predicate logger, :info?
      assert_predicate logger, :warn?
      assert_predicate logger, :error?
      assert_predicate logger, :fatal?
      assert_predicate logger, :unknown?

      {
        debug!: Logger::DEBUG,
        info!: Logger::INFO,
        warn!: Logger::WARN,
        error!: Logger::ERROR,
        fatal!: Logger::FATAL
      }.each do |method_name, level|
        assert_equal level, logger.public_send(method_name)
        assert_equal level, logger.level
      end
    end

    def test_logger_public_level_predicates_track_each_threshold
      logger = Julewire::Rails::Logger.new
      predicates = %i[debug? info? warn? error? fatal? unknown?]
      matrix = {
        -1 => [true, true, true, true, true, true],
        Logger::DEBUG => [true, true, true, true, true, true],
        Logger::INFO => [false, true, true, true, true, true],
        Logger::WARN => [false, false, true, true, true, true],
        Logger::ERROR => [false, false, false, true, true, true],
        Logger::FATAL => [false, false, false, false, true, true],
        Logger::UNKNOWN => [false, false, false, false, false, true]
      }

      matrix.each do |level, expected|
        logger.level = level

        assert_equal(expected, predicates.map { logger.public_send(it) })
      end
    end

    def test_logger_severity_helpers_accept_default_and_explicit_prognames
      output = configure_output
      logger = Julewire::Rails::Logger.new(name: "Rails")

      logger.debug
      logger.info("info-progname")
      logger.warn { "warn block" }
      logger.error("error-progname") { "error block wins" }
      logger.fatal
      logger.unknown("unknown-progname")
      logger.debug("debug-progname") { "debug block wins" }
      logger.info
      logger.info("info-block-progname") { "info block wins" }
      logger.warn("warn-progname") { "warn explicit block" }
      logger.error
      logger.fatal("fatal-progname") { "fatal block wins" }
      logger.unknown
      logger.unknown("unknown-block-progname") { "unknown block wins" }

      records = parse_records(output)

      expected = [
        ["debug", "", "Rails"],
        ["info", "info-progname", "Rails"],
        ["warn", "warn block", "Rails"],
        ["error", "error block wins", "error-progname"],
        ["fatal", "", "Rails"],
        ["unknown", "unknown-progname", "Rails"],
        ["debug", "debug block wins", "debug-progname"],
        ["info", "", "Rails"],
        ["info", "info block wins", "info-block-progname"],
        ["warn", "warn explicit block", "warn-progname"],
        ["error", "", "Rails"],
        ["fatal", "fatal block wins", "fatal-progname"],
        ["unknown", "", "Rails"],
        ["unknown", "unknown block wins", "unknown-block-progname"]
      ]

      actual = records.map do |record|
        [record.fetch("severity"), record.fetch("message"), record.fetch("logger")]
      end

      assert_equal expected, actual
    end

    def test_logger_add_uses_default_arguments_and_explicit_progname
      output = configure_output
      logger = Julewire::Rails::Logger.new(name: "Rails")

      assert_true logger.add(Logger::INFO)
      assert_true logger.add(nil, "unknown message", "explicit-progname")
      assert_true logger.add(Logger::WARN, "warn message")
      assert_true logger.add(12_345, "invalid severity")

      records = parse_records(output)

      assert_equal "info", records.fetch(0).fetch("severity")
      assert_equal "", records.fetch(0).fetch("message")
      assert_equal "Rails", records.fetch(0).fetch("logger")
      assert_equal "unknown", records.fetch(1).fetch("severity")
      assert_equal "unknown message", records.fetch(1).fetch("message")
      assert_equal "explicit-progname", records.fetch(1).fetch("logger")
      assert_equal "warn", records.fetch(2).fetch("severity")
      assert_equal "warn message", records.fetch(2).fetch("message")
      assert_equal "Rails", records.fetch(2).fetch("logger")
      assert_equal "unknown", records.fetch(3).fetch("severity")
      assert_equal "invalid severity", records.fetch(3).fetch("message")
    end

    def test_logger_message_and_block_paths_use_default_logger_name
      output = configure_output
      logger = Julewire::Rails::Logger.new(name: "Rails")

      logger.add(Logger::INFO, "message without progname")
      logger.add(Logger::WARN) { "block without progname" }

      records = parse_records(output)

      assert_equal(["message without progname", "block without progname"], records.map { it.fetch("message") })
      assert_equal(%w[Rails Rails], records.map { it.fetch("logger") })
    end

    def test_logger_add_returns_true_when_suppressed
      output = configure_output
      logger = Julewire::Rails::Logger.new(name: "Rails")

      returned = Julewire::Rails::Suppression.suppress { logger.add(Logger::ERROR, "hidden") }

      assert_true returned
      assert_empty parse_records(output)
    end

    def test_logger_silence_default_and_local_level_cleanup
      output = configure_output
      logger = Julewire::Rails::Logger.new(name: "Rails")

      logger.local_level = :debug

      assert_equal Logger::DEBUG, logger.local_level
      logger.local_level = nil

      assert_nil logger.local_level

      logger.local_level = :warn
      logger.silence do |silenced_logger|
        assert_same logger, silenced_logger
        assert_equal Logger::ERROR, logger.local_level
        logger.warn("hidden")
        logger.error("visible")
      end

      assert_equal Logger::WARN, logger.local_level
      logger.local_level = nil

      assert_equal(["visible"], parse_records(output).map { it.fetch("message") })
    end

    def test_logger_local_level_isolated_between_instances
      first = Julewire::Rails::Logger.new
      second = Julewire::Rails::Logger.new

      first.local_level = :warn
      second.local_level = :debug

      assert_equal Logger::WARN, first.local_level
      assert_equal Logger::DEBUG, second.local_level
    ensure
      first&.local_level = nil
      second&.local_level = nil
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
      custom_error = Class.new(StandardError) do
        def message = "custom-message"

        def to_s = "custom-to-s"
      end.new("custom-message")

      logger.level = :warn

      assert_true logger.add(Logger::INFO, "hidden")
      logger << "unknown line"
      logger.error(RuntimeError.new("boom"))
      logger.error(custom_error)
      logger.warn(message: "structured", payload: "value", extra: 1)
      logger.info!
      logger.info(nil) { "from block" }
      logger.info(nil)

      messages = parse_records(output).map { it.fetch("message") }

      assert_includes messages, "unknown line"
      assert_includes messages, "RuntimeError: boom"
      assert_includes messages, "#{custom_error.class}: custom-message"
      refute_includes messages, "#{custom_error.class}: custom-to-s"
      assert_includes messages, "structured"
      assert_includes messages, "from block"
      assert_includes messages, ""
      assert_includes parse_records(output).map { it.fetch("logger") }, "Rails"
      assert_equal "custom", parse_records(output).first.fetch("source")
      assert_true(parse_records(output).any? { it.key?("error") })
    end

    def test_logger_rejects_invalid_levels_and_copies_progname
      logger = Julewire::Rails::Logger.new(name: +"Rails")

      logger.level = "error"

      assert_equal Logger::ERROR, logger.level
      logger.local_level = "fatal"

      assert_equal Logger::FATAL, logger.local_level
      logger.local_level = nil
      symbol_error = assert_raises(ArgumentError) { logger.level = :invalid }
      string_error = assert_raises(ArgumentError) { logger.local_level = "invalid" }
      invalid_object = Object.new
      type_error = assert_raises(ArgumentError) { logger.level = invalid_object }

      assert_equal "invalid log level: :invalid", symbol_error.message
      assert_equal 'invalid log level: "invalid"', string_error.message
      assert_equal "invalid log level: #{invalid_object.inspect}", type_error.message

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

      with_overridden_singleton_method(Julewire, :flush, proc { :flushed }) do
        assert_equal :flushed, logger.flush
      end

      assert_true cleared
    end

    def test_logger_close_returns_flush_result
      logger = Julewire::Rails::Logger.new

      with_overridden_singleton_method(Julewire, :flush, proc { :closed }) do
        assert_equal :closed, logger.close
      end
    end

    def test_logger_supports_datetime_format_and_reopen_methods
      logger = Julewire::Rails::Logger.new

      logger.datetime_format = "%H:%M"

      assert_equal "%H:%M", logger.datetime_format
      assert_true logger.reopen
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

      assert_true records.fetch(0).dig("payload", "existing")
      assert_equal 1, records.fetch(0).dig("payload", "extra")
      assert_true records.fetch(0).dig("payload", "tags", "explicit")
      assert_equal ["tag-1"], records.fetch(0).dig("attributes", "rails", "tags")
      assert_equal 2, records.fetch(1).dig("payload", "extra")
      assert_false records.fetch(1).fetch("payload").key?("value")
    end

    def test_logger_handles_formatter_without_tag_helpers_and_non_string_progname_copy
      captured = []
      output = configure_output(captured: captured)
      progname = Object.new
      logger = Julewire::Rails::Logger.new(name: progname)
      logger.formatter = Object.new

      copy = logger.dup
      logger.info("plain")
      logger.flush

      assert_same progname, copy.progname
      assert_nil captured.fetch(0).to_h.dig(:attributes, :rails)
      assert_equal "plain", parse_records(output).fetch(0).fetch("message")
      assert_equal progname.to_s, parse_records(output).fetch(0).fetch("logger")
    end

    def test_logger_dup_uses_fresh_local_level_key
      logger = Julewire::Rails::Logger.new(name: +"Rails")
      logger.local_level = :warn

      copy = logger.dup
      copy.local_level = :debug

      assert_equal Logger::WARN, logger.local_level
      assert_equal Logger::DEBUG, copy.local_level
      refute_same logger.progname, copy.progname
    ensure
      logger&.local_level = nil
      copy&.local_level = nil
    end

    def test_logger_multiple_dups_have_isolated_local_level_keys
      logger = Julewire::Rails::Logger.new
      first = logger.dup
      second = logger.dup

      first.local_level = :warn
      second.local_level = :debug

      assert_equal Logger::WARN, first.local_level
      assert_equal Logger::DEBUG, second.local_level
    ensure
      first&.local_level = nil
      second&.local_level = nil
    end

    def test_logger_dup_copies_string_subclass_progname
      progname = Class.new(String).new("Rails")
      logger = Julewire::Rails::Logger.new(name: progname)

      copy = logger.dup

      refute_same progname, copy.progname
      assert_equal "Rails", copy.progname
    end

    def test_logger_nil_payload_does_not_create_value_field_in_raw_record
      captured = []
      configure_output(captured: captured)

      Julewire::Rails::Logger.new.warn(message: "nil payload", extra: 2)

      payload = captured.fetch(0).to_h.fetch(:payload)

      assert_equal 2, payload.fetch(:extra)
      assert_false payload.key?(:value)
    end

    def test_logger_scalar_payload_preserves_value_field
      captured = []
      output = configure_output(captured: captured)

      Julewire::Rails::Logger.new.warn(message: "scalar payload", payload: "value", extra: 1)

      record_payload = parse_records(output).fetch(0).fetch("payload")
      raw_payload = captured.fetch(0).to_h.fetch(:payload)

      assert_equal "value", record_payload.fetch("value")
      assert_equal 1, record_payload.fetch("extra")
      assert_equal "value", raw_payload.fetch(:value)
      assert_equal 1, raw_payload.fetch(:extra)
    end

    def test_logger_hash_subclass_payload_merges_as_payload_hash
      captured = []
      output = configure_output(captured: captured)
      payload = Class.new(Hash).new
      payload[:existing] = true

      Julewire::Rails::Logger.new.warn(message: "hash subclass payload", payload: payload, extra: 1)

      record_payload = parse_records(output).fetch(0).fetch("payload")
      raw_payload = captured.fetch(0).to_h.fetch(:payload)

      assert_true record_payload.fetch("existing")
      assert_equal 1, record_payload.fetch("extra")
      assert_false record_payload.key?("value")
      assert_true raw_payload.fetch(:existing)
      assert_equal 1, raw_payload.fetch(:extra)
      assert_false raw_payload.key?(:value)
    end

    def test_logger_defaults_name_source_and_normalizes_string_hash_keys
      output = configure_output
      logger = Julewire::Rails::Logger.new

      logger.info("message" => "from string key", "event" => "logger.string_key", "extra" => true)

      record = parse_records(output).fetch(0)

      assert_equal "Rails", record.fetch("logger")
      assert_equal "rails", record.fetch("source")
      assert_equal "logger.string_key", record.fetch("event")
      assert_equal "from string key", record.fetch("message")
      assert_true record.dig("payload", "extra")
    end

    def test_logger_uses_top_level_core_for_structured_messages
      output = configure_output
      shadow = Module.new do
        const_set(
          :Fields,
          Module.new do
            def self.const_missing(_name)
              raise "shadow Core namespace used"
            end
          end
        )
      end

      with_constant(Julewire::Rails, :Core, shadow) do
        Julewire::Rails::Logger.new.info(message: "structured", payload: "value", extra: true)
      end

      record = parse_records(output).fetch(0)

      assert_equal "structured", record.fetch("message")
      assert_equal "value", record.dig("payload", "value")
    end

    def test_logger_structured_message_without_payload_keys_omits_payload
      output = configure_output

      Julewire::Rails::Logger.new.info(message: "record only", event: "logger.record_only")

      record = parse_records(output).fetch(0)

      assert_equal "record only", record.fetch("message")
      assert_equal "logger.record_only", record.fetch("event")
      assert_false record.key?("payload")
    end

    def test_logger_treats_hash_subclass_messages_as_structured
      output = configure_output
      message = Class.new(Hash).new
      message[:message] = "hash subclass"
      message[:extra] = true

      Julewire::Rails::Logger.new.warn(message)

      record = parse_records(output).fetch(0)

      assert_equal "hash subclass", record.fetch("message")
      assert_true record.dig("payload", "extra")
    end

    def test_logger_uses_top_level_active_support_execution_state
      logger = Julewire::Rails::Logger.new

      with_shadowed_active_support_execution_state do
        logger.local_level = :warn

        assert_equal Logger::WARN, logger.local_level
        logger.local_level = nil

        assert_nil logger.local_level
      end
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
