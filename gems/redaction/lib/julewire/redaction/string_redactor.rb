# frozen_string_literal: true

module Julewire
  module Redaction
    class StringRedactor
      def initialize(matcher:, mask:, authorization_header: true)
        @matcher = matcher
        @mask = mask.to_s
        @authorization_header = authorization_header
        @redact_pairs = !@matcher.empty?
      end

      def call(value)
        return value unless value.is_a?(String)

        has_colon = value.include?(":")
        has_equals = value.include?("=")
        return value unless redaction_possible?(has_colon, has_equals)

        redacted = value.dup
        redact_header_lines!(redacted) if has_colon
        if @redact_pairs && @matcher.string_key_possible?(value)
          redact_pair_values!(value, redacted, has_colon: has_colon, has_equals: has_equals)
        end
        redacted
      end

      private

      def redaction_possible?(has_colon, has_equals)
        header_redaction_possible?(has_colon) || (@redact_pairs && (has_colon || has_equals))
      end

      def header_redaction_possible?(has_colon)
        @authorization_header && has_colon
      end

      def redact_pair_values!(value, redacted, has_colon:, has_equals:)
        redact_json_pairs!(redacted) if has_colon && (value.include?('"') || value.include?("'"))
        redact_form_pairs!(redacted) if has_equals
      end

      def redact_header_lines!(value)
        value.gsub!(/(\A|[\r\n])([A-Za-z0-9-]+)(:\s*)[^\r\n]*/) do |line|
          name = Regexp.last_match(2)
          next line unless redact_header?(name)

          "#{Regexp.last_match(1)}#{Regexp.last_match(2)}#{Regexp.last_match(3)}#{@mask}"
        end
      end

      def redact_header?(name)
        return true if @authorization_header && name.casecmp?("authorization")

        @matcher.match?(name) || @matcher.match?(name.tr("-", "_"))
      end

      def redact_json_pairs!(value)
        # Defense-in-depth for short log strings; large bodies should stay bounded.
        value.gsub!(/(["'])([^"']+)\1(\s*:\s*)(["'])(?:.*?)\4/) do |pair|
          next pair unless @matcher.match?(Regexp.last_match(2))

          "#{Regexp.last_match(1)}#{Regexp.last_match(2)}#{Regexp.last_match(1)}" \
            "#{Regexp.last_match(3)}#{Regexp.last_match(4)}#{@mask}#{Regexp.last_match(4)}"
        end
      end

      def redact_form_pairs!(value)
        value.gsub!(/(\A|[?&\s])([^?&\s"=]+)(=)(?:[^&\s"]+)/) do |pair|
          next pair unless @matcher.match?(Regexp.last_match(2))

          "#{Regexp.last_match(1)}#{Regexp.last_match(2)}#{Regexp.last_match(3)}#{@mask}"
        end
      end
    end
  end
end
