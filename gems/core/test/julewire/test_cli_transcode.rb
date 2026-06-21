# frozen_string_literal: true

require "test_helper"
require "json"
require "stringio"

module Julewire
  class TestCLITranscode < Minitest::Test
    cover Julewire::Core::CLI::Transcode

    def test_transcode_renders_core_json_from_stdin
      result = transcode_cli(%w[--from core --to core])

      assert_equal 0, result.status
      assert_empty result.stderr
      payload = JSON.parse(result.stdout)

      assert_equal "xcode", payload.fetch("event")
      assert_equal "hello", payload.fetch("message")
      assert_equal "info", payload.fetch("severity")
    end

    def test_transcode_renders_console_text_from_stdin
      result = transcode_cli(%w[--from core --to console])

      assert_equal 0, result.status
      assert_empty result.stderr
      assert_includes result.stdout, "INFO"
      assert_includes result.stdout, "event=xcode"
      assert_includes result.stdout, "hello"
    end

    def test_transcode_supports_inline_options_and_raw_invalid_lines
      result = run_cli(
        %w[transcode --from=core --to=console --theme punk --max-value-bytes 4 --raw-invalid -],
        input: "booting\n#{tail_line(message: "abcdef", event: "xcode")}\n"
      )

      assert_equal 0, result.status
      assert_empty result.stderr
      assert_includes result.stdout, "booting"
      assert_includes result.stdout, ">> INFO >>"
      assert_includes result.stdout, "abcd..."
    end

    def test_transcode_reports_unavailable_output_format
      result = transcode_cli(%w[--from core --to no_such_provider])

      assert_equal 1, result.status
      assert_empty result.stdout
      assert_includes result.stderr, "julewire: log format no_such_provider is not available"
    end

    private

    def transcode_cli(arguments, line: tail_line(message: "hello", event: "xcode"))
      run_cli(["transcode", *arguments, "-"], input: "#{line}\n")
    end
  end
end
