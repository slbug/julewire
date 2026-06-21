# frozen_string_literal: true

module Julewire
  module Core
    class CLI
      class Tail
        include LineHelpers

        DEFAULT_MAX_VALUE_BYTES = Serialization::TextEncoder::DEFAULT_MAX_VALUE_BYTES
        DEFAULT_POLL_INTERVAL = 0.1
        FLAGS = {
          "--color" => [:color, true],
          "--no-color" => [:color, false],
          "--follow" => [:follow, true],
          "--once" => [:follow, false],
          "--plain" => %i[theme plain],
          "--punk" => %i[theme punk],
          "--skip-invalid" => %i[invalid skip],
          "--raw-invalid" => %i[invalid raw]
        }.freeze

        def initialize(argv:, stdin:, stdout:)
          @argv = argv
          @stdin = stdin
          @stdout = stdout
        end

        def call
          options = tail_options
          renderer = tail_renderer(options)
          options.fetch(:path) == "-" ? tail_stdin(options, renderer) : tail_file(options, renderer)
          0
        end

        private

        def tail_options
          parse_command_options(default_tail_options, command: "tail") do |options, value|
            apply_tail_option(options, value)
          end
        end

        def default_tail_options
          {
            color: @stdout.respond_to?(:tty?) && @stdout.tty?,
            format: :auto,
            follow: true,
            invalid: :fail,
            limit: nil,
            max_value_bytes: DEFAULT_MAX_VALUE_BYTES,
            path: nil,
            poll_interval: DEFAULT_POLL_INTERVAL,
            theme: :plain
          }
        end

        def apply_tail_option(options, value)
          if (assignment = FLAGS[value])
            options[assignment.fetch(0)] = assignment.fetch(1)
          elsif value.start_with?("--format=")
            options[:format] = value.delete_prefix("--format=").to_sym
          elsif value == "--format"
            options[:format] = next_symbol_option("--format")
          elsif value == "--theme"
            options[:theme] = next_symbol_option("--theme")
          elsif value == "--limit"
            options[:limit] = positive_integer_option("--limit")
          elsif value == "--max-value-bytes"
            options[:max_value_bytes] = positive_integer_option("--max-value-bytes")
          else
            apply_path_option(options, value, command: "tail")
          end
        end

        def tail_renderer(options)
          encoder = console_text_encoder(options)
          proc do |line, line_number|
            write_encoded_record_line(
              line,
              line_number,
              input_format: options.fetch(:format),
              invalid: options.fetch(:invalid),
              encoder: encoder
            )
          end
        end

        def tail_stdin(options, renderer)
          limit = options.fetch(:limit)
          return render_limited_stdin(limit, renderer) if limit

          render_stream(@stdin.each_line, renderer)
        end

        def tail_file(options, renderer)
          File.open(options.fetch(:path), "r") do |file|
            line_number = render_file_snapshot(file, options, renderer)
            follow_file(file, line_number, options, renderer) if options.fetch(:follow)
          end
        end

        def render_file_snapshot(file, options, renderer)
          entries = indexed_lines(file.each_line)
          render_entries(limit_entries(entries, options.fetch(:limit)), renderer)
          file.seek(0, IO::SEEK_END)
          entries.last&.fetch(0) || 0
        end

        def follow_file(file, line_number, options, renderer)
          loop do
            if (line = file.gets)
              line_number += 1
              render_entries([[line_number, line]], renderer)
            else
              line_number = reset_follow_position(file) if file.stat.size < file.pos
              sleep(options.fetch(:poll_interval))
            end
          end
        end

        def reset_follow_position(file)
          file.seek(0)
          0
        end

        def render_limited_stdin(limit, renderer)
          entries = indexed_lines(@stdin.each_line)
          render_entries(limit_entries(entries, limit), renderer)
        end

        def render_stream(lines, renderer)
          line_number = 0
          lines.each do |line|
            line_number += 1
            next if line.strip.empty?

            renderer.call(line, line_number)
          end
        end

        def limit_entries(entries, limit)
          limit ? entries.last(limit) : entries
        end

        def render_entries(entries, renderer)
          entries.each do |line_number, line|
            renderer.call(line, line_number)
          end
        end
      end
    end
  end
end
