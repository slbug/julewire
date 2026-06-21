# frozen_string_literal: true

module Julewire
  module Rack
    module Capture
      class RequestBody
        class << self
          def call(request, **) = new(request, **).summary_fields
        end

        def initialize(request, content_types:, limit:, mode:)
          @request = request
          @content_types = content_types
          @limit = limit
          @mode = mode
        end

        def summary_fields
          return {} unless BodyContentType.allowed?(@request, selector: @content_types)

          captured, bytes, truncated = capture_body
          return {} if captured.nil? || (captured.empty? && !truncated)

          JsonBody.fields(:request, captured, bytes: bytes, truncated: truncated, mode: @mode)
        end

        private

        def capture_body
          body = bounded_body
          bytes = content_length || body.bytesize
          captured, truncated = capture(body, total_bytes: bytes)
          [captured, bytes, truncated]
        rescue StandardError
          nil
        end

        def bounded_body
          return request_body if @limit.nil?

          length = content_length
          return request_body if length && length <= @limit

          read_body_stream(limit: @limit + 1)
        end

        def request_body
          # Rack/Rails may already buffer raw_post; the byte cap applies after that read.
          return @request.raw_post if @request.respond_to?(:raw_post)

          read_body_stream(limit: nil)
        end

        def read_body_stream(limit:)
          io = @request.body
          original_position = nil
          body = nil
          begin
            original_position = body_stream_position(io)
            body = io.read(limit)
          ensure
            restore_body_stream(io, original_position)
          end
          body.to_str
        end

        def body_stream_position(io)
          io.pos
        rescue StandardError
          nil
        end

        def restore_body_stream(io, original_position)
          io.rewind
        rescue StandardError
          nil
        ensure
          restore_body_stream_position(io, original_position)
        end

        def restore_body_stream_position(io, original_position)
          return unless original_position

          io.pos = original_position
        rescue StandardError
          nil
        end

        def capture(body, total_bytes:)
          return [body, false] if @limit.nil? || total_bytes <= @limit

          [body.byteslice(0, @limit), true]
        end

        def content_length
          value = @request.content_length if @request.respond_to?(:content_length)
          value = @request.get_header("CONTENT_LENGTH") if value.nil?
          integer = Integer(value)
          integer if integer.positive?
        rescue StandardError
          nil
        end
      end
    end
  end
end
