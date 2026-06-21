# frozen_string_literal: true

module Julewire
  module Core
    class CLI
      module LogFormats
        Entry = Data.define(:name, :decoder, :encoder, :priority)
        AUTO_FORMAT = :auto
        FORMAT_NAME_PATTERN = /\A[a-z][a-z0-9_]*\z/

        @entries = []

        class << self
          def register(name, decoder: nil, encoder: nil, priority: 0)
            name = normalize(name)
            validate_component(decoder, :decoder) if decoder
            validate_component(encoder, :encoder) if encoder
            existing = @entries.find { it.name == name }
            priority = priority.to_i
            entry = Entry.new(
              name: name,
              decoder: decoder || existing&.decoder,
              encoder: encoder || existing&.encoder,
              priority: priority.zero? && existing ? existing.priority : priority
            )
            @entries = @entries.reject { it.name == name } + [entry]
            entry
          end

          def decode(payload, format: AUTO_FORMAT)
            raise TypeError, "log entry must be a JSON object" unless payload.is_a?(Hash)

            format = normalize(format)
            entry = format == AUTO_FORMAT ? auto_decode_entry(payload) : named_decode_entry(format, payload)
            entry.decoder.call(payload)
          end

          def encode(record, format:)
            name = normalize(format)
            entry = named_encode_entry(name)
            entry.encoder.call(record)
          end

          def record_from_json_line(line, line_number:, format: AUTO_FORMAT)
            payload = JSON.parse(line)
            Records::Record.from_normalized_hash(decode(payload, format: format))
          rescue JSON::ParserError => e
            raise ArgumentError, "line #{line_number}: invalid JSON: #{e.message}"
          rescue TypeError, ArgumentError => e
            raise ArgumentError, "line #{line_number}: #{e.message}"
          end

          def normalize(value)
            name = Core.normalize_name(value, name: "log format")
            return name if name.to_s.match?(FORMAT_NAME_PATTERN)

            raise ArgumentError, "log format must contain lowercase letters, digits, or underscores"
          end

          def load(name)
            path = "julewire/#{name}"
            require path
          rescue LoadError => e
            raise unless e.path == path
          end

          private

          def validate_component(component, name)
            Validation.validate_callable!(component, name: name)
          end

          def auto_decode_entry(payload)
            entry = decode_entries.find { decoder_match?(it.decoder, payload) }
            raise TypeError, "no log decoder accepted JSON object" unless entry

            entry
          end

          def named_decode_entry(name, payload)
            load_format(name)
            entry = @entries.find { it.name == name && it.decoder }
            raise ArgumentError, "log format #{name} is not available" unless entry
            unless decoder_match?(entry.decoder, payload)
              raise TypeError, "log format #{name} did not accept JSON object"
            end

            entry
          end

          def named_encode_entry(name)
            load_format(name)
            entry = @entries.find { it.name == name && it.encoder }
            raise ArgumentError, "log format #{name} is not available" unless entry

            entry
          end

          def load_format(name)
            return if @entries.any? { it.name == name }

            load(name)
          end

          def decode_entries
            @entries.select(&:decoder).sort_by { [-it.priority, @entries.index(it)] }
          end

          def decoder_match?(decoder, payload)
            return decoder.match?(payload) if decoder.respond_to?(:match?)

            true
          rescue StandardError
            false
          end
        end

        register(:core, decoder: CoreJsonDecoder, encoder: CoreJsonEncoder)
        register(:console, encoder: ConsoleText.new)
      end
    end
  end
end
