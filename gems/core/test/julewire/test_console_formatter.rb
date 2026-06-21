# frozen_string_literal: true

require "test_helper"
require "stringio"

module Julewire
  class TestConsoleFormatter < Minitest::Test
    cover Julewire::Core::Serialization::TextEncoder

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

    def test_text_encoder_punk_theme
      payload = { message: "kick", severity: :warn }

      line = Julewire::TextEncoder.new(color: true, theme: :punk, append_newline: false).call(payload)

      assert_includes line, "\e[93m!! WARN !!\e[0m"
      assert_includes line, "kick"
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
