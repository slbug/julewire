# frozen_string_literal: true

module Julewire
  module Core
    class CLI
      class Transcode
        include LineHelpers

        DEFAULT_MAX_VALUE_BYTES = Serialization::TextEncoder::DEFAULT_MAX_VALUE_BYTES
        FLAGS = {
          "--color" => [:color, true],
          "--no-color" => [:color, false],
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
          options = transcode_options
          encoder = encoder_for(options)
          each_entry(options.fetch(:path)) do |line_number, line|
            write_encoded_record_line(
              line,
              line_number,
              input_format: options.fetch(:from),
              invalid: options.fetch(:invalid),
              encoder: encoder
            )
          end
          0
        end

        private

        def transcode_options
          parse_command_options(default_transcode_options, command: "transcode") do |options, value|
            apply_transcode_option(options, value)
          end
        end

        def default_transcode_options
          {
            color: @stdout.respond_to?(:tty?) && @stdout.tty?,
            from: :auto,
            invalid: :fail,
            max_value_bytes: DEFAULT_MAX_VALUE_BYTES,
            path: nil,
            theme: :plain,
            to: :core
          }
        end

        def apply_transcode_option(options, value)
          if (assignment = FLAGS[value])
            options[assignment.fetch(0)] = assignment.fetch(1)
          elsif value.start_with?("--")
            apply_named_option(options, value)
          else
            apply_path_option(options, value, command: "transcode")
          end
        end

        def apply_named_option(options, value)
          if value.start_with?("--from=")
            options[:from] = value.delete_prefix("--from=").to_sym
          elsif value.start_with?("--to=")
            options[:to] = value.delete_prefix("--to=").to_sym
          else
            apply_separate_option(options, value)
          end
        end

        def apply_separate_option(options, value)
          case value
          when "--from" then options[:from] = next_symbol_option("--from")
          when "--to" then options[:to] = next_symbol_option("--to")
          when "--theme" then options[:theme] = next_symbol_option("--theme")
          when "--max-value-bytes" then options[:max_value_bytes] = positive_integer_option("--max-value-bytes")
          else
            apply_path_option(options, value, command: "transcode")
          end
        end

        def encoder_for(options)
          return console_text_encoder(options) if options.fetch(:to) == :console

          ->(record) { LogFormats.encode(record, format: options.fetch(:to)) }
        end

        def each_entry(path, &)
          return indexed_lines(@stdin.each_line).each(&) if path == "-"

          File.open(path, "r") { |file| indexed_lines(file.each_line).each(&) }
        end
      end
    end
  end
end
