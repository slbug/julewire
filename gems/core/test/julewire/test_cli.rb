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

  class EachLineCLIInput
    def initialize(lines)
      @lines = lines
    end

    def each_line = @lines.each

    def each = ["wrong\n"].each
  end

  class CLIInvalidLinePolicyProbe
    include Core::CLI::LineHelpers

    def initialize(stdout)
      @stdout = stdout
    end

    def call(line, mode)
      handle_invalid_line(line, mode)
    end

    def indexed(lines)
      indexed_lines(lines)
    end
  end

  class CLITailProbe < Core::CLI::Tail
    def initialize(stdout: StringIO.new)
      super(argv: [], stdin: StringIO.new, stdout: stdout)
    end

    def default_options = __send__(:default_tail_options)

    def render_snapshot(file, limit:)
      rendered = []
      line_number = __send__(
        :render_file_snapshot,
        file,
        { limit: limit },
        proc { |line, number| rendered << [number, line] }
      )
      [line_number, rendered]
    end

    def follow_once(file, line_number, poll_interval: 0.01)
      rendered = []
      __send__(
        :follow_file,
        file,
        line_number,
        { poll_interval: poll_interval },
        proc { |line, number| rendered << [number, line] }
      )
      rendered
    rescue StopIteration
      rendered
    end

    def reset_position(file) = __send__(:reset_follow_position, file)
  end

  class CLIFollowFile
    Stat = Data.define(:size)

    attr_reader :pos, :seeks

    def initialize(lines:, size:, pos:)
      @lines = lines
      @size = size
      @pos = pos
      @seeks = []
    end

    def gets = @lines.shift

    def stat = Stat.new(@size)

    def seek(position)
      @seeks << position
      @pos = position
    end
  end

  class CLISnapshotFile
    attr_reader :seeks

    def initialize(lines)
      @lines = lines
      @seeks = []
    end

    def each_line = @lines.each

    def each = ["wrong\n"].each

    def seek(*args)
      @seeks << args
      :seeked
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

    def test_tail_accepts_mutable_dash_path_as_stdin
      line = tail_line(message: "hello", event: "tail.event")
      dash = +"-"

      result = run_cli(["tail", dash], input: "#{line}\n")

      assert_equal 0, result.status
      assert_empty result.stderr
      assert_includes result.stdout, "event=tail.event"
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
        refute_includes auto.stdout, "core.event"
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

    def test_tail_raw_invalid_adds_missing_newline
      result = run_cli(%w[tail --raw-invalid -], input: "booting app")

      assert_equal 0, result.status
      assert_empty result.stderr
      assert_equal "booting app\n", result.stdout
    end

    def test_invalid_line_policy_rejects_unknown_mode
      stdout = StringIO.new
      raised = assert_raises(ArgumentError) do
        CLIInvalidLinePolicyProbe.new(stdout).call("booting", :panic)
      end

      assert_equal "invalid line policy must be fail, raw, or skip", raised.message
      assert_empty stdout.string
    end

    def test_indexed_lines_omits_blank_lines_without_placeholder_entries
      indexed = CLIInvalidLinePolicyProbe.new(StringIO.new).indexed(["one\n", " \t\n", "two\n"])

      assert_equal [[1, "one\n"], [3, "two\n"]], indexed
    end

    def test_tail_limit_keeps_last_lines
      input = [
        tail_line(message: "first", event: "tail.first"),
        tail_line(message: "second", event: "tail.second")
      ].join("\n")

      result = run_cli(%w[tail --limit 1 -], input: "#{input}\n")

      assert_equal 0, result.status
      assert_empty result.stderr
      refute_includes result.stdout, "first"
      assert_includes result.stdout, "second"
      refute_includes result.stdout, "tail.first"
      assert_includes result.stdout, "tail.second"
    end

    def test_tail_limited_stdin_reads_each_line_and_does_not_replay_stream
      input = EachLineCLIInput.new([
                                     "#{tail_line(message: "first", event: "tail.first")}\n",
                                     "#{tail_line(message: "second", event: "tail.second")}\n"
                                   ])
      stdout = StringIO.new

      status = Core::CLI.call(argv: %w[tail --limit 1 -], stdin: input, stdout: stdout, stderr: StringIO.new)

      assert_equal 0, status
      refute_includes stdout.string, "wrong"
      refute_includes stdout.string, "tail.first"
      assert_includes stdout.string, "tail.second"
    end

    def test_tail_stream_skips_blank_stdin_lines
      line = tail_line(message: "hello", event: "tail.event")

      result = run_cli(%w[tail -], input: "\n#{line}\n\n")

      assert_equal 0, result.status
      assert_empty result.stderr
      assert_includes result.stdout, "event=tail.event"
    end

    def test_tail_theme_option_changes_console_theme
      line = tail_line(message: "hello", event: "tail.event")

      result = run_cli(%w[tail --theme punk -], input: "#{line}\n")

      assert_equal 0, result.status
      assert_empty result.stderr
      assert_includes result.stdout, ">> INFO >>"
    end

    def test_tail_max_value_bytes_option_truncates_console_values
      line = tail_line(message: "abcdef", event: "tail.event")

      result = run_cli(%w[tail --max-value-bytes 3 -], input: "#{line}\n")

      assert_equal 0, result.status
      assert_empty result.stderr
      assert_includes result.stdout, "abc..."
      refute_includes result.stdout, "abcdef"
    end

    def test_tail_streams_stdin_without_waiting_for_eof
      input = BlockingCLIInput.new
      output = QueueCLIOutput.new
      error_output = StringIO.new
      thread = safe_thread do
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

        result = run_cli(["tail", "--once", "--limit", "1", file.path], timeout: 0.1)

        assert_equal 0, result.status
        assert_empty result.stderr
        refute_includes result.stdout, "first"
        assert_includes result.stdout, "second"
        refute_includes result.stdout, "tail.first"
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

        thread = safe_thread do
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

      status = begin
        Julewire::Core::CLI.call(
          argv: %w[tail -],
          stdin: InterruptingCLIInput.new,
          stdout: stdout,
          stderr: stderr
        )
      rescue Interrupt
        :escaped_interrupt
      end

      assert_equal 130, status
      assert_empty stdout.string
      assert_empty stderr.string
    end

    def test_tail_reports_missing_path
      assert_cli_failure(%w[tail], "julewire: tail log path is required")
    end

    def test_tail_reports_missing_option_values_with_option_names
      {
        %w[tail --format] => "--format value is required",
        %w[tail --theme] => "--theme value is required",
        %w[tail --limit] => "--limit value is required",
        %w[tail --max-value-bytes] => "--max-value-bytes value is required"
      }.each do |argv, message|
        assert_cli_failure(argv, "julewire: #{message}")
      end
    end

    def test_tail_rejects_invalid_positive_integer_options
      %w[0 -1 0x10 a nope].each do |value|
        assert_cli_failure(["tail", "--limit", value, "-"], "julewire: --limit must be a positive integer")
      end
    end

    def test_tail_accepts_decimal_limit_digits
      line = tail_line(message: "hello", event: "tail.event")
      result = run_cli(%w[tail --limit 9 -], input: "#{line}\n")

      assert_equal 0, result.status
      assert_includes result.stdout, "event=tail.event"
    end

    def test_tail_default_options_read_tty_predicate_only_when_supported
      no_tty = Object.new
      tty_false = StringIO.new
      tty_false.define_singleton_method(:tty?) { false }
      tty_true = StringIO.new
      tty_true.define_singleton_method(:tty?) { true }

      assert_false CLITailProbe.new(stdout: no_tty).default_options.fetch(:color)
      assert_false CLITailProbe.new(stdout: tty_false).default_options.fetch(:color)
      assert_true CLITailProbe.new(stdout: tty_true).default_options.fetch(:color)
    end

    def test_tail_file_snapshot_uses_file_lines_seeks_to_end_and_returns_last_physical_line_number
      file = CLISnapshotFile.new([
                                   "\n",
                                   "#{tail_line(message: "first", event: "tail.first")}\n",
                                   "#{tail_line(message: "second", event: "tail.second")}\n"
                                 ])

      line_number, rendered = CLITailProbe.new.render_snapshot(file, limit: 1)

      assert_equal 3, line_number
      assert_equal 3, rendered.fetch(0).fetch(0)
      assert_includes rendered.fetch(0).fetch(1), "tail.second"
      assert_equal [[0, IO::SEEK_END]], file.seeks
    end

    def test_tail_file_snapshot_returns_zero_for_empty_files
      file = StringIO.new("")

      line_number, rendered = CLITailProbe.new.render_snapshot(file, limit: nil)

      assert_equal 0, line_number
      assert_empty rendered
      assert_equal 0, file.pos
    end

    def test_tail_follow_increments_line_numbers_and_sleeps_when_idle
      file = CLIFollowFile.new(lines: ["new\n", nil], size: 3, pos: 3)
      tail = CLITailProbe.new
      sleeps = []

      rendered = with_bounded_tail_sleep(sleeps, stop_after: 1) do
        safe_thread_value(safe_thread { tail.follow_once(file, 2, poll_interval: 0.25) }, timeout: 0.1)
      end

      assert_equal [[3, "new\n"]], rendered
      assert_equal [0.25], sleeps
      assert_empty file.seeks
    end

    def test_tail_follow_resets_after_truncation_before_numbering_new_lines
      file = CLIFollowFile.new(lines: [nil, "after\n", nil], size: 0, pos: 5)
      tail = CLITailProbe.new

      rendered = with_bounded_tail_sleep([], stop_after: 2) do
        safe_thread_value(safe_thread { tail.follow_once(file, 9, poll_interval: 0.25) }, timeout: 0.1)
      end

      assert_equal [[1, "after\n"]], rendered
      assert_equal [0], file.seeks
    end

    def test_tail_reset_follow_position_seeks_to_start_and_returns_zero
      file = CLISnapshotFile.new(["old\n"])

      line_number = CLITailProbe.new.reset_position(file)

      assert_equal 0, line_number
      assert_equal [[0]], file.seeks
    end

    def with_bounded_tail_sleep(sleeps, stop_after:, &)
      replacement = proc do |interval|
        sleeps << interval
        raise StopIteration if sleeps.length >= stop_after
      end

      with_overridden_singleton_method(Kernel, :sleep, replacement, &)
    end

    def test_tail_reports_repeated_path_with_command_name
      assert_cli_failure(%w[tail first.log second.log], "julewire: tail accepts one log path")
    end

    def test_tail_rejects_unknown_path_position_option
      assert_cli_failure(%w[tail --bogus], "julewire: unknown option --bogus")
    end

    def test_transcode_separate_options_render_console_output
      line = tail_line(message: "abcdef", event: "transcode.event")

      result = run_cli(%w[transcode --from core --to console --theme punk --max-value-bytes 3 -], input: "#{line}\n")

      assert_equal 0, result.status
      assert_empty result.stderr
      assert_includes result.stdout, ">> INFO >>"
      assert_includes result.stdout, "abc..."
      refute_includes result.stdout, "abcdef"
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

    def test_help_aliases_print_usage
      [%w[-h], %w[help], []].each do |argv|
        result = run_cli(argv)

        assert_equal 0, result.status
        assert_empty result.stderr
        assert_includes result.stdout, "julewire tail"
      end
    end

    def test_version_prints_core_version
      result = run_cli(%w[--version])

      assert_equal 0, result.status
      assert_empty result.stderr
      assert_equal "julewire #{Core::VERSION}\n", result.stdout
    end

    def test_version_uses_core_version_not_cli_local_constant
      Core::CLI.const_set(:VERSION, "wrong")

      result = run_cli(%w[--version])

      assert_equal 0, result.status
      assert_equal "julewire #{Core::VERSION}\n", result.stdout
    ensure
      Core::CLI.__send__(:remove_const, :VERSION) if Core::CLI.const_defined?(:VERSION, false)
    end

    def test_call_does_not_mutate_caller_argv
      argv = %w[--version]

      result = run_cli(argv)

      assert_equal 0, result.status
      assert_equal %w[--version], argv
    end

    def test_call_uses_default_global_streams_for_success
      stdout = StringIO.new

      status = with_cli_globals(argv: %w[--version], stdout: stdout) do
        Core::CLI.call
      end

      assert_equal 0, status
      assert_equal "julewire #{Core::VERSION}\n", stdout.string
    end

    def test_call_uses_default_global_error_stream_for_failures
      stderr = StringIO.new

      status = with_cli_globals(argv: %w[nope], stderr: stderr) do
        Core::CLI.call
      end

      assert_equal 1, status
      assert_equal "julewire: unknown command \"nope\"\n", stderr.string
    end

    def test_call_uses_default_global_input_stream_for_tail
      stdout = StringIO.new
      input = StringIO.new("#{tail_line(message: "global stdin", event: "tail.event")}\n")

      status = with_cli_globals(argv: %w[tail --limit 1 -], stdin: input, stdout: stdout) do
        Core::CLI.call
      end

      assert_equal 0, status
      assert_includes stdout.string, "global stdin"
    end

    def test_version_aliases_print_core_version
      [%w[-v], %w[version]].each do |argv|
        result = run_cli(argv)

        assert_equal 0, result.status
        assert_empty result.stderr
        assert_equal "julewire #{Core::VERSION}\n", result.stdout
      end
    end

    def test_unknown_command_fails
      assert_cli_failure(%w[nope], 'julewire: unknown command "nope"')
    end

    def test_empty_string_command_fails
      assert_cli_failure([""], 'julewire: unknown command ""')
    end

    private

    def assert_cli_failure(argv, message, input: "")
      result = run_cli(argv, input: input)

      assert_equal 1, result.status
      assert_empty result.stdout
      assert_includes result.stderr, message
    end

    def with_cli_globals(argv:, stdin: StringIO.new, stdout: StringIO.new, stderr: StringIO.new)
      previous_argv = ARGV.dup
      previous_stdin = $stdin
      previous_stdout = $stdout
      previous_stderr = $stderr
      ARGV.replace(argv)
      $stdin = stdin
      $stdout = stdout
      $stderr = stderr
      yield
    ensure
      ARGV.replace(previous_argv)
      $stdin = previous_stdin
      $stdout = previous_stdout
      $stderr = previous_stderr
    end

    def assert_mixed_stream_tail(flag, raw:)
      input = "booting app\n#{tail_line(message: "hello", event: "tail.event")}\n"

      result = run_cli(["tail", flag, "-"], input: input)

      assert_equal 0, result.status
      assert_empty result.stderr
      if raw
        assert_includes result.stdout, "booting app"
      else
        refute_includes result.stdout, "booting app"
      end

      assert_includes result.stdout, "event=tail.event"
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
