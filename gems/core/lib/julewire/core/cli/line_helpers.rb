# frozen_string_literal: true

module Julewire
  module Core
    class CLI
      module LineHelpers
        private

        def parse_command_options(options, command:)
          @argv.length.times do
            break if @argv.empty?

            yield(options, @argv.shift)
          end
          raise ArgumentError, "#{command} log path is required" unless options.fetch(:path)

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

          begin
            integer = Integer(value, 10)
            raise ArgumentError unless integer.positive?

            integer
          rescue ArgumentError
            raise ArgumentError, "#{name} must be a positive integer"
          end
        end

        def apply_path_option(options, value, command:)
          raise ArgumentError, "unknown option #{value}" if value.start_with?("-") && !value.eql?("-")
          raise ArgumentError, "#{command} accepts one log path" if options.fetch(:path)

          options[:path] = value
        end

        def handle_invalid_line(line, mode)
          case mode
          when :skip
            nil
          when :raw
            @stdout.write(raw_line(line))
          when :fail
            raise
          else
            raise ArgumentError, "invalid line policy must be fail, raw, or skip"
          end
        end

        def raw_line(line)
          line.end_with?("\n") ? line : "#{line}\n"
        end

        def indexed_lines(lines)
          lines.each_with_index.filter_map do |line, index|
            [index + 1, line] if line.match?(/\S/)
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
        rescue ArgumentError
          handle_invalid_line(line, invalid)
        end
      end
    end
  end
end
