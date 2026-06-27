# frozen_string_literal: true

require "test_helper"
require "stringio"

module Julewire
  class NoTTYOutput
    def initialize
      @buffer = StringIO.new
    end

    def write(value)
      @buffer.write(value)
    end

    def string = @buffer.string
  end

  class TestConsoleFormatter < Minitest::Test
    cover Julewire::ConsoleFormatter
    cover Julewire::TextEncoder
    cover Julewire::Tail
    cover "Julewire::Core::FacadeMethods#dev!"
    cover "Julewire::Core::FacadeMethods#punk!"
    cover "Julewire::Core::FacadeMethods#tail"
    class PayloadHash < Hash; end

    KEYS = Julewire::Core::Fields::AttributeKeys

    def test_console_formatter_and_text_encoder_render_human_line
      record = build_console_record(
        {
          event: "tail.error",
          message: "boom",
          payload: { account_id: "acct-1" },
          severity: :error,
          source: "test"
        },
        attributes: { hidden: "not-rendered" }
      )
      payload = Julewire::ConsoleFormatter.new.call(record)
      line = Julewire::TextEncoder.new(append_newline: false).call(payload)

      assert_includes line, "ERROR"
      assert_includes line, "event=tail.error"
      assert_includes line, "source=test"
      assert_includes line, "boom"
      assert_includes line, "\"account_id\":\"acct-1\""
      refute_includes line, "hidden"
    end

    def test_console_formatter_uses_shared_display_message
      record = build_console_record(
        {
          error: RuntimeError.new("123"),
          event: "request.completed",
          metrics: { duration_ms: 273.828 },
          severity: :error
        },
        neutral: {
          KEYS::HTTP_REQUEST_METHOD => "GET",
          KEYS::HTTP_RESPONSE_STATUS_CODE => 500,
          KEYS::URL_PATH => "/julewire_probe"
        }
      )

      payload = Julewire::ConsoleFormatter.new.call(record)
      line = Julewire::TextEncoder.new(append_newline: false).call(payload)

      assert_equal "GET /julewire_probe -> 500 RuntimeError in 273.828ms", payload.fetch(:message)
      assert_includes line, payload.fetch(:message)
    end

    def test_console_formatter_projects_validated_record_shape
      record = build_console_record(
        {
          event: "console.shape",
          message: "shape",
          payload: { account_id: "acct-1" },
          severity: :warn,
          source: "test"
        }
      )

      payload = Julewire::ConsoleFormatter.new.call(record)

      assert_equal %i[event labels message payload severity source timestamp], payload.keys
      assert_equal "console.shape", payload.fetch(:event)
      assert_equal({}, payload.fetch(:labels))
      assert_equal "shape", payload.fetch(:message)
      assert_equal({ account_id: "acct-1" }, payload.fetch(:payload))
      assert_equal :warn, payload.fetch(:severity)
      assert_equal "test", payload.fetch(:source)
      assert_equal record.fetch(:timestamp), payload.fetch(:timestamp)
    end

    def test_console_formatter_rejects_invalid_record_shape
      error = assert_raises(TypeError) do
        Julewire::ConsoleFormatter.new.call(message: "not normalized")
      end

      assert_equal "expected Julewire::Record", error.message
    end

    def test_text_encoder_colorizes_and_truncates
      payload = {
        message: "abcdefghijklmnop",
        severity: :error,
        timestamp: Time.utc(2026, 6, 12, 10, 0, 0)
      }

      line = Julewire::TextEncoder.new(color: true, max_value_bytes: 8, append_newline: false).call(payload)

      assert_includes line, "\e[31mERROR\e[0m"
      assert_includes line, "abcdefgh..."
      assert_includes line, "2026-06-12T10:00:00.000000Z"
    end

    def test_text_encoder_colorizes_unknown_severity_with_neutral_style
      line = Julewire::TextEncoder.new(color: true, append_newline: false).call(severity: :notice)

      assert_equal "\e[37mNOTICE\e[0m", line
    end

    def test_text_encoder_omits_blank_timestamp_values
      line = Julewire::TextEncoder.new(append_newline: false).call(timestamp: "", message: "ready")

      assert_equal "INFO  ready", line
    end

    def test_text_encoder_keeps_non_iso_timestamp_values
      line = Julewire::TextEncoder.new(append_newline: false).call(timestamp: "unix:42", message: "ready")

      assert_equal "unix:42 INFO  ready", line
    end

    def test_text_encoder_reads_string_keyed_payloads
      payload = {
        "event" => "text.event",
        "message" => "hello",
        "payload" => { "account_id" => "acct-1" },
        "severity" => "warn"
      }

      line = Julewire::TextEncoder.new(append_newline: false).call(payload)

      assert_includes line, "WARN"
      assert_includes line, "event=text.event"
      assert_includes line, "hello"
      assert_includes line, 'payload={"account_id":"acct-1"}'
    end

    def test_text_encoder_treats_string_subclasses_as_text
      value = Class.new(String).new("already encoded")

      line = Julewire::TextEncoder.new(append_newline: false).call(value)

      assert_equal "already encoded", line
    end

    def test_text_encoder_includes_labels_section
      line = Julewire::TextEncoder.new(append_newline: false).call(labels: { component: "worker" })

      assert_includes line, 'labels={"component":"worker"}'
    end

    def test_text_encoder_defaults_missing_severity_to_info
      line = Julewire::TextEncoder.new(append_newline: false).call(message: "ready")

      assert_equal "INFO  ready", line
    end

    def test_text_encoder_uses_to_s_for_message_values
      message = Object.new
      message.define_singleton_method(:to_s) { "object message" }

      line = Julewire::TextEncoder.new(append_newline: false).call(message: message)

      assert_equal "INFO  object message", line
    end

    def test_text_encoder_does_not_truncate_exact_limit_values
      line = Julewire::TextEncoder.new(max_value_bytes: 4, append_newline: false).call(message: "1234")

      assert_includes line, "1234"
      refute_includes line, "1234..."
    end

    def test_text_encoder_does_not_truncate_under_limit_values
      line = Julewire::TextEncoder.new(max_value_bytes: 4, append_newline: false).call(message: "123")

      assert_includes line, "123"
      refute_includes line, "123..."
    end

    def test_text_encoder_scrubs_partial_multibyte_truncation
      line = Julewire::TextEncoder.new(max_value_bytes: 3, append_newline: false).call(message: "éé")

      assert_predicate line, :valid_encoding?
      assert_includes line, "é?..."
    end

    def test_text_encoder_rejects_zero_max_value_bytes
      error = assert_raises(ArgumentError) do
        Julewire::TextEncoder.new(max_value_bytes: 0)
      end

      assert_equal "max_value_bytes must be a positive Integer", error.message
    end

    def test_text_encoder_compact_hash_omits_empty_hashes_and_accepts_hash_subclasses
      payload = PayloadHash[account_id: "acct-1"]

      line = Julewire::TextEncoder.new(append_newline: false).call(payload: payload, labels: {})

      assert_includes line, "payload={\"account_id\":\"acct-1\"}"
      refute_includes line, "labels="
    end

    def test_text_encoder_compact_hash_omits_non_hash_sections
      line = Julewire::TextEncoder.new(append_newline: false).call(payload: "raw", labels: ["debug"])

      refute_includes line, "payload="
      refute_includes line, "labels="
    end

    def test_text_encoder_compact_hash_truncates_json_rendering
      line = Julewire::TextEncoder.new(max_value_bytes: 12, append_newline: false).call(
        payload: { value: "abcdefghij" }
      )

      assert_includes line, 'payload={"value":"ab...'
      refute_includes line, "abcdefghij"
    end

    def test_text_encoder_compact_hash_falls_back_when_json_rejects_value
      line = Julewire::TextEncoder.new(append_newline: false).call(payload: { nan: Float::NAN })

      assert_includes line, "payload={nan: NaN}"
    end

    def test_text_encoder_compact_hash_truncates_fallback_rendering
      line = Julewire::TextEncoder.new(max_value_bytes: 8, append_newline: false).call(payload: { nan: Float::NAN })

      assert_includes line, "payload={nan: Na..."
      refute_includes line, "payload={nan: NaN}"
    end

    def test_text_encoder_punk_theme
      payload = { message: "kick", severity: :warn }

      line = Julewire::TextEncoder.new(color: true, theme: :punk, append_newline: false).call(payload)

      assert_includes line, "\e[93m!! WARN !!\e[0m"
      assert_includes line, "kick"
    end

    def test_text_encoder_punk_glyph_accepts_symbol_and_unknown_severity
      assert_equal "!!", Julewire::TextEncoder.punk_glyph(:warn)
      assert_equal "XX", Julewire::TextEncoder.punk_glyph("error")
      assert_equal "??", Julewire::TextEncoder.punk_glyph(:notice)
    end

    def test_text_encoder_rejects_unknown_theme
      error = assert_raises(ArgumentError) do
        Julewire::TextEncoder.new(theme: :corporate)
      end

      assert_equal "text encoder theme must be one of: plain, punk", error.message
    end

    def test_punk_configures_console_destination
      output = StringIO.new

      Julewire.punk!(output: output, color: false)
      Julewire.warn("noise")

      assert_includes output.string, "!! WARN !!"
      assert_includes output.string, "noise"
    end

    def test_punk_defaults_to_stdout_color_and_no_banner_or_chaos
      original_stdout = $stdout
      $stdout = StringIO.new

      Julewire.punk!
      Julewire.warn("noise")

      refute_includes $stdout.string, "!!JULEWIRE PUNK!!"
      assert_includes $stdout.string, "\e[93m!! WARN !!\e[0m"
      assert_includes $stdout.string, "noise"
      assert_equal :ok, destination_health.fetch(:status)
    ensure
      $stdout = original_stdout
    end

    def test_punk_replaces_existing_destinations
      first_output = StringIO.new
      punk_output = StringIO.new

      Julewire.configure do |config|
        configure_destination(config, name: :extra, output: first_output)
      end
      Julewire.punk!(output: punk_output, color: false)
      Julewire.warn("noise")

      assert_empty first_output.string
      assert_equal [:default], Julewire.health.dig(:pipeline, :destinations).keys
      assert_includes punk_output.string, "noise"
    end

    def test_punk_chaos_contains_output_failures
      output = StringIO.new

      Julewire.punk!(
        output: output,
        color: false,
        chaos: { rate: 1, mode: :raise },
        banner: true
      )
      Julewire.warn("noise")

      health = destination_health

      assert_includes output.string, "!!JULEWIRE PUNK!!"
      refute_includes output.string, "noise"
      assert_equal :degraded, health.fetch(:status)
      assert_equal 1, health.dig(:counts, :output_exception)
      assert_equal :output_exception, health.dig(:last_loss, :reason)
    end

    def test_dev_configures_punk_console_and_tail
      output = StringIO.new

      tail = Julewire.dev!(output: output, color: false, tail: { capacity: 2 })
      Julewire.warn("noise")

      assert_instance_of Julewire::Tail, tail
      assert_equal 1, tail.records.length
      assert_includes output.string, "!! WARN !!"
      assert_includes output.string, "noise"
    end

    def test_dev_uses_tty_color_and_default_tail
      output = StringIO.new
      output.define_singleton_method(:tty?) { true }

      tail = Julewire.dev!(output: output)
      Julewire.warn("noise")

      assert_instance_of Julewire::Tail, tail
      assert_equal 1, tail.records.length
      assert_includes output.string, "\e[93m!! WARN !!\e[0m"
    end

    def test_dev_defaults_to_global_stdout
      original_stdout = $stdout
      $stdout = StringIO.new

      Julewire.dev!(color: false, tail: false)
      Julewire.info("global ready")

      assert_includes $stdout.string, "global ready"
    ensure
      $stdout = original_stdout
    end

    def test_dev_defaults_to_plain_output_for_non_tty_output
      output = StringIO.new

      Julewire.dev!(output: output, tail: false)
      Julewire.warn("plain")

      refute_includes output.string, "\e["
      refute_includes output.string, "!!JULEWIRE PUNK!!"
      assert_includes output.string, "!! WARN !!"
    end

    def test_dev_respects_explicit_color_for_non_tty_output
      output = StringIO.new

      Julewire.dev!(output: output, color: true, tail: false)
      Julewire.warn("colored")

      assert_includes output.string, "\e[93m!! WARN !!\e[0m"
    end

    def test_dev_respects_explicit_color_for_tty_output
      output = StringIO.new
      output.define_singleton_method(:tty?) { true }

      Julewire.dev!(output: output, color: false, tail: false)
      Julewire.warn("plain")

      refute_includes output.string, "\e["
      assert_includes output.string, "!! WARN !!"
    end

    def test_dev_defaults_to_color_for_output_without_tty_predicate
      output = NoTTYOutput.new

      Julewire.dev!(output: output, tail: false)
      Julewire.warn("colored")

      assert_includes output.string, "\e[93m!! WARN !!\e[0m"
    end

    def test_dev_chaos_enables_banner_by_default
      output = StringIO.new

      Julewire.dev!(output: output, color: false, chaos: { rate: 0 }, tail: false)

      assert_includes output.string, "!!JULEWIRE PUNK!!"
    end

    def test_punk_chaos_enables_banner_by_default
      output = StringIO.new

      Julewire.punk!(output: output, color: false, chaos: { rate: 0 })

      assert_includes output.string, "!!JULEWIRE PUNK!!"
    end

    def test_dev_can_disable_banner_when_chaos_is_enabled
      output = StringIO.new

      Julewire.dev!(output: output, color: false, chaos: { rate: 0 }, banner: false, tail: false)

      refute_includes output.string, "!!JULEWIRE PUNK!!"
    end

    def test_dev_forwards_chaos_to_punk_destination
      output = StringIO.new

      Julewire.dev!(
        output: output,
        color: false,
        chaos: { rate: 1, mode: :raise },
        banner: false,
        tail: false
      )
      Julewire.warn("noise")

      refute_includes output.string, "noise"
      assert_equal :degraded, destination_health.fetch(:status)
    end

    def test_dev_uses_named_runtime_and_forwards_tail_options
      output = StringIO.new
      tail_options = Class.new(Hash).new.merge!(capacity: 1)

      tail = Julewire.dev!(:custom, output: output, color: false, tail: tail_options)
      Julewire.runtime(:custom).emit("first")
      Julewire.runtime(:custom).emit("second")

      assert_instance_of Julewire::Tail, tail
      assert_equal(["second"], tail.records.map { it.fetch("message") })
      assert_includes output.string, "first"
      assert_includes output.string, "second"
    end

    def test_dev_can_skip_tail
      output = StringIO.new

      tail = Julewire.dev!(output: output, color: false, tail: false)
      Julewire.info("ready")

      assert_nil tail
      assert_equal [:default], Julewire.health.dig(:pipeline, :destinations).keys
      assert_includes output.string, "ready"
    end

    def test_dev_rejects_invalid_tail_options
      error = assert_raises(ArgumentError) do
        Julewire.dev!(output: StringIO.new, color: false, tail: :yes)
      end

      assert_equal "tail must be true, false, or an options Hash", error.message
    end

    def test_text_encoder_appends_newline_to_text_payloads
      assert_equal "ready\n", Julewire::TextEncoder.new.call("ready")
    end

    def test_console_formatter_writes_through_direct_destination_as_text
      output = StringIO.new

      Julewire.configure do |config|
        configure_destination(
          config,
          encoder: Julewire::TextEncoder.new,
          formatter: Julewire::ConsoleFormatter.new,
          output: output
        )
      end

      Julewire.error("boom", event: "console.error")

      assert_includes output.string, "ERROR"
      assert_includes output.string, "event=console.error"
      assert_includes output.string, "boom"
      refute_includes output.string, "{\""
      assert_equal "\n", output.string[-1]
    end

    private

    def build_console_record(input, attributes: {}, neutral: {})
      Julewire::Core::Records::Draft.build(
        input,
        attributes: attributes,
        carry: {},
        context: {},
        neutral: neutral,
        scope: nil
      ).to_record
    end
  end
end
