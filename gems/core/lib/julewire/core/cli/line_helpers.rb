# frozen_string_literal: true

module Julewire
  module Core
    class CLI
      module LineHelpers
        private

        def parse_command_options(options, command:)
          yield(options, @argv.shift) until @argv.empty?
          raise ArgumentError, "#{command} log path is required" unless options[:path]

          options
        end

        def next_symbol_option(name)
          value = @argv.shift
          raise ArgumentError, "#{name} value is required" unless value

          value.to_sym
        end

        def positive_integer_option(name)
          value = @argv.shift
          raise ArgumentError, "#{name} value is required" unless value

          Validation.validate_integer_limit!(Integer(value, 10), name: name.delete_prefix("--"), positive: true)
        rescue ArgumentError
          raise ArgumentError, "#{name} must be a positive integer"
        end

        def apply_path_option(options, value, command:)
          raise ArgumentError, "unknown option #{value}" if value.start_with?("-") && value != "-"
          raise ArgumentError, "#{command} accepts one log path" if options[:path]

          options[:path] = value
        end

        def handle_invalid_line(line, error, mode)
          case mode
          when :skip
            nil
          when :raw
            @stdout.write(raw_line(line))
          else
            raise error
          end
        end

        def raw_line(line)
          line.end_with?("\n") ? line : "#{line}\n"
        end

        def indexed_lines(lines)
          lines.each_with_index.filter_map do |line, index|
            [index + 1, line] unless line.strip.empty?
          end
        end

        def console_text_encoder(options)
          LogFormats::ConsoleText.new(
            color: options.fetch(:color),
            max_value_bytes: options.fetch(:max_value_bytes),
            theme: options.fetch(:theme)
          )
        end

        def write_encoded_record_line(line, line_number, input_format:, invalid:, encoder:)
          record = LogFormats.record_from_json_line(line, line_number: line_number, format: input_format)
          @stdout.write(encoder.call(record))
        rescue ArgumentError => e
          handle_invalid_line(line, e, invalid)
        end
      end
    end
  end
end
