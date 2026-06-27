# frozen_string_literal: true

require "test_helper"
require "json"
require "stringio"
require "tempfile"

module Julewire
  class TestCLITranscode < Minitest::Test
    cover Julewire::Core::CLI::Transcode
    cover Julewire::Core::CLI::LogFormats
    cover "Julewire::Core::CLI::Transcode#apply_separate_option"

    def test_transcode_defaults_to_auto_input_core_output_and_fail_invalid
      result = transcode_cli([])

      assert_equal 0, result.status
      assert_empty result.stderr

      payload = JSON.parse(result.stdout)

      assert_equal "xcode", payload.fetch("event")
      assert_equal "hello", payload.fetch("message")
    end

    def test_transcode_default_invalid_policy_fails
      result = run_cli(%w[transcode -], input: "not-json\n")

      assert_equal 1, result.status
      assert_empty result.stdout
      assert_includes result.stderr, "julewire:"
    end

    def test_transcode_defaults_to_tty_color_for_console_output
      stdout = TtyStringIO.new

      status, stderr = transcode_console_to(stdout)

      assert_equal 0, status
      assert_empty stderr.string
      assert_includes stdout.string, "\e[32mINFO \e[0m"
    end

    def test_transcode_defaults_to_plain_console_output_for_non_tty
      stdout = NonTtyStringIO.new

      status, stderr = transcode_console_to(stdout)

      assert_equal 0, status
      assert_empty stderr.string
      refute_includes stdout.string, "\e["
    end

    def test_transcode_defaults_to_plain_console_output_without_tty_predicate
      stdout = WriteOnlyOutput.new

      status, stderr = transcode_console_to(stdout)

      assert_equal 0, status
      assert_empty stderr.string
      refute_includes stdout.string, "\e["
    end

    def test_transcode_reads_stdin_with_each_line
      stdout = StringIO.new
      stderr = StringIO.new

      status = Julewire::Core::CLI.call(
        argv: %w[transcode -],
        stdin: LineInput.new(["#{tail_line(message: "hello", event: "xcode")}\n"]),
        stdout: stdout,
        stderr: stderr
      )

      assert_equal 0, status
      assert_empty stderr.string
      assert_equal "xcode", JSON.parse(stdout.string).fetch("event")
    end

    def test_transcode_renders_core_json_from_stdin
      result = transcode_cli(%w[--from core --to core])

      assert_equal 0, result.status
      assert_empty result.stderr
      payload = JSON.parse(result.stdout)

      assert_equal "xcode", payload.fetch("event")
      assert_equal "hello", payload.fetch("message")
      assert_equal "info", payload.fetch("severity")
    end

    def test_transcode_renders_core_json_from_file_path
      Tempfile.create("julewire-transcode") do |file|
        file.write("#{tail_line(message: "first", event: "one")}\n")
        file.write("#{tail_line(message: "second", event: "two")}\n")
        file.flush

        result = run_cli(%W[transcode --from core --to core #{file.path}], input: "")

        assert_equal 0, result.status
        assert_empty result.stderr

        records = result.stdout.lines.map { JSON.parse(it) }

        assert_equal(%w[one two], records.map { it.fetch("event") })
        assert_equal(%w[first second], records.map { it.fetch("message") })
      end
    end

    def test_transcode_renders_console_text_from_stdin
      result = transcode_cli(%w[--from core --to console])

      assert_equal 0, result.status
      assert_empty result.stderr
      assert_includes result.stdout, "INFO"
      assert_includes result.stdout, "event=xcode"
      assert_includes result.stdout, "hello"
    end

    def test_console_text_format_defaults_to_plain_uncolored_output
      line = console_text_line(event: "xcode", message: "hello", severity: :info)

      assert_includes line, "INFO "
      assert_includes line, "event=xcode"
      assert_includes line, "hello"
      refute_includes line, "\e["
      refute_includes line, ">> INFO >>"
    end

    def test_console_text_format_uses_default_value_limit
      message = "x" * (Julewire::Core::Serialization::TextEncoder::DEFAULT_MAX_VALUE_BYTES + 1)
      line = Julewire::Core::CLI::LogFormats::ConsoleText.new.call(
        build_record({ event: "xcode", message: message, severity: :info })
      )

      assert_includes line, "#{"x" * Julewire::Core::Serialization::TextEncoder::DEFAULT_MAX_VALUE_BYTES}..."
      refute_includes line, message
    end

    def test_console_text_format_uses_record_formatter_display_message
      line = Julewire::Core::CLI::LogFormats::ConsoleText.new.call(
        build_record({
                       event: "xcode",
                       error: { class: "RuntimeError", message: "boom" },
                       message: nil,
                       severity: :error
                     })
      )

      assert_includes line, "ERROR"
      assert_includes line, "RuntimeError: boom"
    end

    def test_console_text_format_uses_internal_core_constants
      without_constant(Julewire, :TextEncoder) do
        without_constant(Julewire, :ConsoleFormatter) do
          line = console_text_line(event: "xcode", message: "hello", severity: :info)

          assert_includes line, "INFO "
          assert_includes line, "event=xcode"
          assert_includes line, "hello"
        end
      end
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

    def test_transcode_supports_separated_named_options
      result = run_cli(
        %w[transcode --from core --to console --theme punk --max-value-bytes 4 -],
        input: "#{tail_line(message: "abcdef", event: "xcode")}\n"
      )

      assert_equal 0, result.status
      assert_empty result.stderr
      assert_includes result.stdout, ">> INFO >>"
      assert_includes result.stdout, "abcd..."
    end

    def test_transcode_separated_options_report_missing_values_by_name
      {
        "--from" => %w[--from],
        "--to" => %w[--to],
        "--theme" => %w[--theme],
        "--max-value-bytes" => %w[--max-value-bytes]
      }.each do |option, arguments|
        assert_transcode_failure(arguments, "julewire: #{option} value is required")
      end
    end

    def test_transcode_reports_unavailable_output_format
      result = transcode_cli(%w[--from core --to no_such_provider])

      assert_equal 1, result.status
      assert_empty result.stdout
      assert_includes result.stderr, "julewire: log format no_such_provider is not available"
    end

    def test_transcode_inline_from_uses_requested_decoder
      result = transcode_cli(%w[--from=missing_format])

      assert_equal 1, result.status
      assert_empty result.stdout
      assert_includes result.stderr, "julewire: line 1: log format missing_format is not available"
    end

    def test_transcode_separated_from_uses_requested_decoder
      result = transcode_cli(%w[--from missing_format])

      assert_equal 1, result.status
      assert_empty result.stdout
      assert_includes result.stderr, "julewire: line 1: log format missing_format is not available"
    end

    def test_transcode_inline_to_uses_requested_encoder
      result = transcode_cli(%w[--from=core --to=no_such_provider])

      assert_equal 1, result.status
      assert_empty result.stdout
      assert_includes result.stderr, "julewire: log format no_such_provider is not available"
    end

    def test_transcode_rejects_unknown_path_position_option
      assert_transcode_failure(%w[--bogus], "julewire: unknown option --bogus")
    end

    def test_transcode_reports_missing_path_with_command_name
      assert_transcode_failure([], "julewire: transcode log path is required")
    end

    def test_transcode_reports_repeated_path_with_command_name
      assert_transcode_failure(%w[first.log second.log], "julewire: transcode accepts one log path")
    end

    private

    def assert_transcode_failure(arguments, message)
      result = run_cli(["transcode", *arguments], input: "")

      assert_equal 1, result.status
      assert_empty result.stdout
      assert_includes result.stderr, message
    end

    def transcode_cli(arguments, line: tail_line(message: "hello", event: "xcode"))
      run_cli(["transcode", *arguments, "-"], input: "#{line}\n")
    end

    def transcode_console_to(stdout)
      stderr = StringIO.new
      status = Julewire::Core::CLI.call(
        argv: %w[transcode --to console -],
        stdin: StringIO.new("#{tail_line(message: "hello", event: "xcode")}\n"),
        stdout: stdout,
        stderr: stderr
      )

      [status, stderr]
    end

    def console_text_line(**fields)
      Julewire::Core::CLI::LogFormats::ConsoleText.new.call(build_record(fields))
    end

    class TtyStringIO < StringIO
      def tty? = true
    end

    class NonTtyStringIO < StringIO
      def tty? = false
    end

    class WriteOnlyOutput
      attr_reader :string

      def initialize
        @string = +""
      end

      def write(value)
        @string << value
      end
    end

    class LineInput
      def initialize(lines)
        @lines = lines
      end

      def each_line
        @lines.each
      end
    end
  end
end
