# frozen_string_literal: true

module Julewire
  module Rack
    module Capture
      class BufferedResponseBody
        class << self
          def call(response, **) = new(response, **).summary_fields
        end

        def initialize(response, content_types:, limit:, mode: Settings::STRING_BODY)
          @response = response
          @content_types = content_types
          @limit = limit
          @mode = mode
          @captured = +""
          @total_bytes = 0
          @truncated = false
        end

        def summary_fields
          return {} unless BodyContentType.allowed?(@response, selector: @content_types)

          body_parts = response_body_parts
          return {} unless body_parts

          if @limit.nil?
            fields = unlimited_single_part_fields(body_parts)
            return fields if fields
          end

          capture(body_parts)
          return {} if @total_bytes.zero? && @captured.empty?

          JsonBody.fields(:response, @captured, bytes: @total_bytes, truncated: @truncated, mode: @mode)
        end

        private

        def response_body_parts
          return unless @response.respond_to?(:stream)

          stream = @response.stream
          return if stream.respond_to?(:to_path)
          return unless stream.respond_to?(:to_ary)

          stream.to_ary
        rescue StandardError
          nil
        end

        def capture(body_parts)
          body_parts.each do |part|
            body = body_string(part)
            next unless body

            capture_part(body)
          end
        end

        def body_string(part)
          return part.to_str if part.respond_to?(:to_str)

          nil
        rescue StandardError
          nil
        end

        def unlimited_single_part_fields(body_parts)
          return unless body_parts.length == 1

          body = body_string(body_parts.first)
          return {} unless body && !body.empty?

          JsonBody.fields(:response, body, bytes: body.bytesize, truncated: false, mode: @mode)
        end

        def capture_part(body)
          bytesize = body.bytesize
          @total_bytes += bytesize

          return @captured << body if @limit.nil?

          remaining = @limit - @captured.bytesize
          if remaining <= 0
            @truncated = true if bytesize.positive?
            return
          end

          @captured << body.byteslice(0, remaining)
          @truncated = true if bytesize > remaining
        end
      end
    end
  end
end
