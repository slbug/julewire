# frozen_string_literal: true

require "json"
require "time"

module Julewire
  module Core
    module Serialization
      # @api extension
      class TextEncoder
        SEVERITY_STYLES = {
          "debug" => 36,
          "info" => 32,
          "warn" => 33,
          "error" => 31,
          "fatal" => 35,
          "unknown" => 37
        }.freeze
        PUNK_SEVERITY_STYLES = {
          "debug" => 36,
          "info" => 92,
          "warn" => 93,
          "error" => 91,
          "fatal" => 95,
          "unknown" => 97
        }.freeze
        PUNK_SEVERITY_GLYPHS = {
          "debug" => "..",
          "info" => ">>",
          "warn" => "!!",
          "error" => "XX",
          "fatal" => "##",
          "unknown" => "??"
        }.freeze
        THEMES = %i[plain punk].freeze
        DEFAULT_MAX_VALUE_BYTES = 160

        class << self
          def punk_glyph(severity)
            PUNK_SEVERITY_GLYPHS.fetch(severity.to_s, PUNK_SEVERITY_GLYPHS.fetch("unknown"))
          end
        end

        def initialize(max_value_bytes: DEFAULT_MAX_VALUE_BYTES, color: false, append_newline: true, theme: :plain)
          @max_value_bytes = Validation.validate_integer_limit!(
            max_value_bytes,
            name: :max_value_bytes,
            positive: true
          )
          @color = color
          @line_suffix = append_newline ? "\n" : ""
          @theme = validate_theme(theme)
        end

        def call(payload)
          text = payload.is_a?(String) ? payload : line_for(payload)
          "#{text}#{@line_suffix}"
        end

        private

        def line_for(payload)
          fields = [
            timestamp(payload),
            severity(payload),
            label(payload, :event),
            label(payload, :source),
            message(payload),
            compact_hash(:payload, value_at(payload, :payload)),
            compact_hash(:labels, value_at(payload, :labels))
          ].compact
          fields.join(" ")
        end

        def validate_theme(theme)
          Validation.validate_symbol_choice!(theme, name: "text encoder theme", choices: THEMES)
        end

        def timestamp(payload)
          value = value_at(payload, :timestamp)
          return if blank?(value)
          # Console output is human-facing; JSON keeps nanosecond precision.
          return value.iso8601(6) if value.respond_to?(:iso8601)

          value.to_s
        end

        def severity(payload)
          value = (value_at(payload, :severity) || :info).to_s
          label = severity_label(value)
          return label unless @color

          code = severity_styles.fetch(value, 37)
          "\e[#{code}m#{label}\e[0m"
        end

        def severity_label(value)
          label = value.upcase.ljust(5)
          return label unless @theme == :punk

          glyph = self.class.punk_glyph(value)
          "#{glyph} #{value.upcase} #{glyph}"
        end

        def severity_styles
          @theme == :punk ? PUNK_SEVERITY_STYLES : SEVERITY_STYLES
        end

        def label(payload, key)
          value = value_at(payload, key)
          return if blank?(value)

          "#{key}=#{value}"
        end

        def message(payload)
          value = value_at(payload, :message)
          return if blank?(value)

          truncate(value.to_s)
        end

        def compact_hash(name, value)
          return unless value.is_a?(Hash) && !value.empty?

          "#{name}=#{truncate(JSON.generate(value, allow_nan: false))}"
        rescue StandardError
          "#{name}=#{truncate(value.inspect)}"
        end

        def truncate(value)
          return value if value.bytesize <= @max_value_bytes

          "#{value.byteslice(0, @max_value_bytes).scrub("?")}..."
        end

        def value_at(payload, key)
          Fields::Lookup.value(payload, key)
        end

        def blank?(value)
          Fields::Lookup.blank?(value)
        end
      end
    end
  end
end
