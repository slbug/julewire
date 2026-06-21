# frozen_string_literal: true

require "test_helper"
require "json"
require "stringio"
require "tempfile"

module Julewire
  class QueueCLIOutput
    def initialize
      @values = Queue.new
      @buffer = +""
      @mutex = Mutex.new
    end

    def write(value)
      @mutex.synchronize { @buffer << value }
      @values << value
    end

    def string
      @mutex.synchronize { @buffer.dup }
    end

    def pop(timeout: 1)
      @values.pop(timeout: timeout)
    end

    def tty? = false
  end

  class InterruptingCLIInput
    def each_line
      raise Interrupt
    end
  end

  class BlockingCLIInput
    STOP = Object.new.freeze

    def initialize = @lines = Queue.new

    def write(line) = @lines << line

    def close = @lines << STOP

    def each_line
      return enum_for(:each_line) unless block_given?

      loop do
        line = @lines.pop
        break if line.equal?(STOP)

        yield line
      end
    end
  end

  class TestCLI < Minitest::Test
    cover Julewire::Core::CLI

    def test_tail_renders_julewire_json_lines_from_stdin
      line = JSON.generate(
        "timestamp" => "2026-06-19T10:00:00Z",
        "severity" => "warn",
        "kind" => "point",
        "event" => "tail.event",
        "message" => "hello",
        "source" => "test",
        "execution" => {},
        "context" => {},
        "attributes" => {},
        "payload" => { "account_id" => "acct-1" }
      )

      result = run_cli(%w[tail -], input: "#{line}\n")

      assert_equal 0, result.status
      assert_empty result.stderr
      assert_includes result.stdout, "WARN"
      assert_includes result.stdout, "event=tail.event"
      assert_includes result.stdout, "source=test"
      assert_includes result.stdout, "hello"
      assert_includes result.stdout, "\"account_id\":\"acct-1\""
    end

    def test_tail_supports_explicit_core_format
      line = tail_line(message: "hello", event: "tail.event")

      result = run_cli(%w[tail --format=core -], input: "#{line}\n")

      assert_equal 0, result.status
      assert_empty result.stderr
      assert_includes result.stdout, "event=tail.event"
      assert_includes result.stdout, "hello"
    end

    def test_tail_auto_rejects_non_julewire_json
      line = JSON.generate("severity" => "INFO", "message" => "booting")

      result = run_cli(%w[tail -], input: "#{line}\n")

      assert_equal 1, result.status
      assert_empty result.stdout
      assert_includes result.stderr, "line 1: no log decoder accepted JSON object"
    end

    def test_tail_auto_prefers_registered_provider_decoder_over_core_shape
      line = tail_line(message: "hello", event: "core.event")

      with_log_formats do
        Core::CLI::LogFormats.register(
          :test_provider,
          decoder: log_decoder_record(event: "provider.event", message: "provider"),
          priority: 100
        )

        auto = run_cli(%w[tail -], input: "#{line}\n")
        explicit_core = run_cli(%w[tail --format core -], input: "#{line}\n")

        assert_equal 0, auto.status
        assert_includes auto.stdout, "event=provider.event"
        assert_omits auto.stdout, "core.event"
        assert_equal 0, explicit_core.status
        assert_includes explicit_core.stdout, "event=core.event"
      end
    end

    def test_tail_raw_invalid_keeps_non_julewire_json
      line = JSON.generate("severity" => "INFO", "message" => "booting")

      result = run_cli(%w[tail --raw-invalid -], input: "#{line}\n")

      assert_equal 0, result.status
      assert_empty result.stderr
      assert_equal "#{line}\n", result.stdout
    end

    def test_tail_limit_keeps_last_lines
      input = [
        tail_line(message: "first", event: "tail.first"),
        tail_line(message: "second", event: "tail.second")
      ].join("\n")

      result = run_cli(%w[tail --limit 1 -], input: "#{input}\n")

      assert_equal 0, result.status
      assert_empty result.stderr
      assert_omits result.stdout, "first"
      assert_includes result.stdout, "second"
      assert_omits result.stdout, "tail.first"
      assert_includes result.stdout, "tail.second"
    end

    def test_tail_streams_stdin_without_waiting_for_eof
      input = BlockingCLIInput.new
      output = QueueCLIOutput.new
      error_output = StringIO.new
      thread = Thread.new do
        Core::CLI.call(argv: %w[tail -], stdin: input, stdout: output, stderr: error_output)
      end

      input.write("#{tail_line(message: "streamed", event: "tail.stream")}\n")

      assert_includes output.pop, "streamed"
    ensure
      input&.close
      cleanup_thread(thread)
    end

    def test_tail_once_reads_file_and_exits
      Tempfile.create("julewire-cli") do |file|
        file.write("#{tail_line(message: "first", event: "tail.first")}\n")
        file.write("#{tail_line(message: "second", event: "tail.second")}\n")
        file.flush

        result = run_cli(["tail", "--once", "--limit", "1", file.path])

        assert_equal 0, result.status
        assert_empty result.stderr
        assert_omits result.stdout, "first"
        assert_includes result.stdout, "second"
        assert_omits result.stdout, "tail.first"
        assert_includes result.stdout, "tail.second"
      end
    end

    def test_tail_follows_file_by_default
      thread = nil
      Tempfile.create("julewire-cli") do |file|
        output = QueueCLIOutput.new
        error_output = StringIO.new
        file.write("#{tail_line(message: "first", event: "tail.first")}\n")
        file.flush

        thread = Thread.new do
          Julewire::Core::CLI.call(
            argv: ["tail", "--limit", "1", file.path],
            stdin: StringIO.new,
            stdout: output,
            stderr: error_output
          )
        end

        assert_includes output.pop, "first"
        file.write("#{tail_line(message: "second", event: "tail.second")}\n")
        file.flush

        assert_includes output.pop, "second"
        assert_empty error_output.string
      ensure
        cleanup_thread(thread, timeout: 0.1)
      end
    end

    def test_tail_reports_invalid_json_line
      assert_cli_failure(%w[tail -], "julewire: line 1: invalid JSON", input: "{bad\n")
    end

    def test_tail_can_skip_invalid_lines
      assert_mixed_stream_tail("--skip-invalid", raw: false)
    end

    def test_tail_can_print_invalid_lines_raw
      assert_mixed_stream_tail("--raw-invalid", raw: true)
    end

    def test_tail_reports_unavailable_provider_format
      assert_cli_failure(
        %w[tail --format provider_json -],
        "julewire: line 1: log format provider_json is not available",
        input: "#{tail_line(message: "hello", event: "tail.event")}\n"
      )
    end

    def test_tail_rejects_unsafe_format_name
      assert_cli_failure(
        %w[tail --format=../provider_json -],
        "julewire: line 1: log format must contain lowercase letters, digits, or underscores",
        input: "#{tail_line(message: "hello", event: "tail.event")}\n"
      )
    end

    def test_tail_exits_cleanly_on_interrupt
      stdout = StringIO.new
      stderr = StringIO.new

      status = Julewire::Core::CLI.call(
        argv: %w[tail -],
        stdin: InterruptingCLIInput.new,
        stdout: stdout,
        stderr: stderr
      )

      assert_equal 130, status
      assert_empty stdout.string
      assert_empty stderr.string
    end

    def test_tail_reports_missing_path
      assert_cli_failure(%w[tail], "julewire: tail log path is required")
    end

    def test_help_prints_usage
      result = run_cli(%w[--help])

      assert_equal 0, result.status
      assert_empty result.stderr
      assert_includes result.stdout, "julewire tail"
      assert_includes result.stdout, "--follow|--once"
      assert_includes result.stdout, "julewire transcode"
      assert_includes result.stdout, "--theme plain|punk"
      assert_includes result.stdout, "julewire doctor"
      assert_includes result.stdout, "julewire --version"
    end

    def test_version_prints_core_version
      result = run_cli(%w[--version])

      assert_equal 0, result.status
      assert_empty result.stderr
      assert_equal "julewire #{Core::VERSION}\n", result.stdout
    end

    def test_unknown_command_fails
      assert_cli_failure(%w[nope], 'julewire: unknown command "nope"')
    end

    private

    def assert_cli_failure(argv, message, input: "")
      result = run_cli(argv, input: input)

      assert_equal 1, result.status
      assert_empty result.stdout
      assert_includes result.stderr, message
    end

    def assert_omits(value, substring)
      assert_nil value.index(substring), "Expected #{value.inspect} to omit #{substring.inspect}"
    end

    def assert_mixed_stream_tail(flag, raw:)
      input = "booting app\n#{tail_line(message: "hello", event: "tail.event")}\n"

      result = run_cli(["tail", flag, "-"], input: input)

      assert_equal 0, result.status
      assert_empty result.stderr
      if raw
        assert_includes result.stdout, "booting app"
      else
        assert_omits result.stdout, "booting app"
      end

      assert_includes result.stdout, "event=tail.event"
    end

    def with_log_formats
      original = Core::CLI::LogFormats.instance_variable_get(:@entries)
      yield
    ensure
      Core::CLI::LogFormats.instance_variable_set(:@entries, original)
    end

    def log_decoder_record(**fields)
      record = normalized_record(**fields)
      Module.new do
        define_singleton_method(:match?) { |_payload| true }
        define_singleton_method(:call) { |_payload| record }
      end
    end
  end
end
