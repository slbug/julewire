# frozen_string_literal: true

require "test_helper"
require "rack/mock"
require "rack/request"
require "stringio"

module Julewire
  class TestCaptureHelpers < Minitest::Test # rubocop:disable Metrics/ClassLength -- Capture helper edge matrix.
    cover Julewire::Rack::Capture::BodyContentType
    cover Julewire::Rack::Capture::RequestBody

    def test_body_content_type_edges
      request = json_request('{"ok":true}', content_type: "application/vnd.api+json")

      assert Julewire::Rack::Capture::BodyContentType.allowed?(
        request,
        selector: Julewire::Rack::Capture::BodyContentType::JSON_ONLY
      )
      refute Julewire::Rack::Capture::BodyContentType.allowed?(request, selector: nil)
      refute Julewire::Rack::Capture::BodyContentType.allowed?(double_content_type("image/png"), selector: true)
      assert Julewire::Rack::Capture::BodyContentType.allowed?(
        double_content_type("text/plain"),
        selector: %w[text/plain]
      )
      assert_equal "application/json",
                   Julewire::Rack::Capture::BodyContentType.media_type_for(
                     double_headers("Content-Type" => json_header)
                   )
      assert_equal "application/json",
                   Julewire::Rack::Capture::BodyContentType.media_type_for(double_mime_type("application/json"))
      assert_equal "application/json",
                   Julewire::Rack::Capture::BodyContentType.media_type_for(double_get_header("application/json"))
      assert_nil Julewire::Rack::Capture::BodyContentType.raw_content_type(nil)
      assert_nil Julewire::Rack::Capture::BodyContentType.header_value(Object.new, "content-type")
    end

    def test_body_content_type_selector_and_binary_edges
      capture = Julewire::Rack::Capture::BodyContentType

      assert capture.allowed?(double_content_type("TEXT/PLAIN; charset=utf-8"), selector: "text/plain")
      assert capture.allowed?(double_content_type("text/plain"), selector: " TEXT/PLAIN ; charset=utf-8")
      assert capture.allowed?(double_content_type(nil), selector: true)
      assert_same false, capture.allowed?(double_content_type("false"), selector: false)
      refute capture.allowed?(double_content_type(nil), selector: "text/plain")
      refute capture.allowed?(double_content_type("text/plain"), selector: false)
      refute capture.allowed?(double_content_type("text/plain"), selector: :json)
    end

    def test_body_content_type_regex_and_binary_edges
      capture = Julewire::Rack::Capture::BodyContentType

      assert capture.allowed?(double_content_type("application/activity+json"), selector: /\+json\z/)
      refute capture.allowed?(double_content_type("text/plain"), selector: /json/)
      refute capture.allowed?(double_content_type("application/pdf"), selector: true)
      refute capture.allowed?(double_content_type("audio/mpeg"), selector: true)
      refute capture.allowed?(double_content_type(nil), selector: /^$/)
      assert capture.binary?(object_stringified_as("image/png"))
    end

    def test_body_content_type_reader_priority_and_header_variants
      capture = Julewire::Rack::Capture::BodyContentType

      assert_equal "application/vnd.api+json",
                   capture.media_type_for(double_media_type("APPLICATION/VND.API+JSON; charset=utf-8"))
      assert_equal "application/xml", capture.media_type_for(double_mime_type("application/xml"))
      assert_equal "application/json", capture.media_type_for(double_content_type("application/json"))
      assert_equal "text/plain", capture.media_type_for(double_get_header_for("CONTENT_TYPE" => "text/plain"))
      assert_equal "application/json", capture.media_type_for(double_content_type(" application/json ; charset=utf-8 "))
      assert_equal "text/plain", capture.media_type_for(double_mime_type_with_fallback(nil, "text/plain"))
      assert_equal "application/json",
                   capture.media_type_for(
                     double_media_type_with_fallback("application/json", "text/plain")
                   )
      assert_equal "", capture.media_type_for(nil)
      assert_nil capture.raw_content_type(double_raising_content_type)
    end

    def test_body_content_type_direct_reader_converts_mime_objects
      capture = Julewire::Rack::Capture::BodyContentType

      assert_equal "application/xml",
                   capture.direct_content_type(
                     double_mime_type(object_stringified_as("application/xml"))
                   )
    end

    def test_body_content_type_header_variants
      capture = Julewire::Rack::Capture::BodyContentType

      assert_equal "text/html", capture.media_type_for(double_headers("content-type" => "text/html"))
      assert_equal "text/css", capture.media_type_for(double_headers("CONTENT-TYPE" => "text/css"))
      assert_equal "application/javascript",
                   capture.media_type_for(double_headers("Content-Type" => "application/javascript"))
      assert_nil capture.header_content_type(Object.new)
      assert_nil capture.header_content_type(nil)
      assert_nil capture.header_value({}, "content-type")
    end

    def test_request_body_capture_standard_and_truncated_edges
      request = json_request('{"ok":true}', content_type: "application/vnd.api+json")

      assert_equal(
        { "request_body" => '{"ok":true}', "request_body_bytes" => 11, "request_body_truncated" => false },
        stringify_keys(request_body_fields(request, limit: nil))
      )
      assert_equal(
        { "request_body" => "", "request_body_bytes" => 11, "request_body_truncated" => true },
        stringify_keys(request_body_fields(request, limit: 0))
      )
    end

    def test_request_body_capture_requires_allowed_content_type_before_reading
      request = json_request('{"ok":true}', content_type: "text/plain")

      assert_empty Julewire::Rack::Capture::RequestBody.call(
        request,
        content_types: Julewire::Rack::Capture::BodyContentType::JSON_ONLY,
        limit: nil,
        mode: Julewire::Rack::Capture::Settings::STRING_BODY
      )
    end

    def test_request_body_capture_rejects_binary_body_even_when_selector_is_true
      request = json_request("binary", content_type: "image/png")

      assert_empty Julewire::Rack::Capture::RequestBody.call(
        request,
        content_types: true,
        limit: nil,
        mode: Julewire::Rack::Capture::Settings::STRING_BODY
      )
    end

    def test_request_body_capture_uses_raw_post_when_content_length_fits_limit
      request = double_raw_post_with_body_stream(
        raw_post: "raw",
        content_length: "3",
        body: raising_read_stream
      )

      assert_equal(
        { "request_body" => "raw", "request_body_bytes" => 3, "request_body_truncated" => false },
        stringify_keys(request_body_fields(request, limit: 5))
      )
    end

    def test_request_body_capture_uses_raw_post_when_content_length_equals_limit
      request = double_raw_post_with_body_stream(
        raw_post: '{"ok":true}',
        content_length: "11",
        body: raising_read_stream
      )

      assert_equal(
        { "request_body" => '{"ok":true}', "request_body_bytes" => 11, "request_body_truncated" => false },
        stringify_keys(request_body_fields(request, limit: 11))
      )
    end

    def test_request_body_capture_uses_bounded_stream_when_content_length_exceeds_limit
      stream = limit_tracking_stream("abcdef")
      request = double_raw_post_with_body_stream(
        raw_post: proc { raise "raw post should not be read when body is oversized" },
        content_length: "12",
        body: stream
      )

      assert_equal(
        { "request_body" => "abc", "request_body_bytes" => 12, "request_body_truncated" => true },
        stringify_keys(request_body_fields(request, limit: 3))
      )
      assert_equal [4], stream.limits
    end

    def test_request_body_capture_reads_bounded_stream_and_restores_position
      stream = StringIO.new("hello world")
      stream.pos = 6
      request = double_body(stream, content_length: "20")

      assert_equal(
        { "request_body" => "world", "request_body_bytes" => 20, "request_body_truncated" => true },
        stringify_keys(request_body_fields(request, limit: 10))
      )
      assert_equal 6, stream.pos
    end

    def test_request_body_capture_reads_stream_without_position_support
      request = double_body(no_position_stream("body"))

      assert_equal(
        { "request_body" => "body", "request_body_bytes" => 4, "request_body_truncated" => false },
        stringify_keys(request_body_fields(request, limit: nil))
      )
    end

    def test_request_body_capture_coerces_stream_read_value_with_to_str
      request = double_body(no_position_stream(string_like("body")))

      assert_equal(
        { "request_body" => "body", "request_body_bytes" => 4, "request_body_truncated" => false },
        stringify_keys(request_body_fields(request, limit: nil))
      )
    end

    def test_request_body_capture_does_not_restore_missing_position
      stream = no_position_writer_stream("body")
      request = double_body(stream)

      assert_equal(
        { "request_body" => "body", "request_body_bytes" => 4, "request_body_truncated" => false },
        stringify_keys(request_body_fields(request, limit: nil))
      )
      assert_empty stream.assigned_positions
    end

    def test_request_body_capture_contains_position_restore_failure
      request = double_body(failing_position_restore_stream("body"))

      assert_equal(
        { "request_body" => "body", "request_body_bytes" => 4, "request_body_truncated" => false },
        stringify_keys(request_body_fields(request, limit: nil))
      )
    end

    def test_request_body_capture_reads_stream_without_rewind_support
      stream = no_rewind_position_stream("body")
      request = double_body(stream)

      assert_equal(
        { "request_body" => "body", "request_body_bytes" => 4, "request_body_truncated" => false },
        stringify_keys(request_body_fields(request, limit: nil))
      )
      assert_equal 0, stream.pos
    end

    def test_request_body_capture_uses_header_content_length_for_bounded_fast_path
      stream = limit_tracking_stream("abcd")
      request = double_body_with_header_length(stream, "4")

      assert_equal(
        { "request_body" => "abcd", "request_body_bytes" => 4, "request_body_truncated" => false },
        stringify_keys(request_body_fields(request, limit: 10))
      )
      assert_equal [nil], stream.limits
    end

    def test_request_body_capture_ignores_non_positive_content_length
      zero_stream = limit_tracking_stream("zero")
      negative_stream = limit_tracking_stream("negative")

      assert_equal(
        { "request_body" => "zero", "request_body_bytes" => 4, "request_body_truncated" => false },
        stringify_keys(request_body_fields(double_body(zero_stream, content_length: "0"), limit: 10))
      )
      assert_equal(
        { "request_body" => "negative", "request_body_bytes" => 8, "request_body_truncated" => false },
        stringify_keys(request_body_fields(double_body(negative_stream, content_length: "-1"), limit: 10))
      )
      assert_equal [11], zero_stream.limits
      assert_equal [11], negative_stream.limits
    end

    def test_request_body_capture_prefers_direct_content_length_over_header
      request = double_body_with_content_length_and_header(
        raising_read_stream,
        content_length: "3",
        header_length: "20",
        raw_post: "raw"
      )

      assert_equal(
        { "request_body" => "raw", "request_body_bytes" => 3, "request_body_truncated" => false },
        stringify_keys(request_body_fields(request, limit: 5))
      )
    end

    def test_request_body_capture_does_not_mark_under_limit_body_as_truncated
      request = json_request('{"ok":true}')

      assert_equal(
        { "request_body" => '{"ok":true}', "request_body_bytes" => 11, "request_body_truncated" => false },
        stringify_keys(request_body_fields(request, limit: 20))
      )
    end

    def test_request_body_capture_does_not_mark_exact_limit_body_as_truncated
      request = json_request('{"ok":true}')

      assert_equal(
        { "request_body" => '{"ok":true}', "request_body_bytes" => 11, "request_body_truncated" => false },
        stringify_keys(request_body_fields(request, limit: 11))
      )
    end

    def test_request_body_capture_omits_empty_untruncated_body
      assert_empty request_body_fields(json_request(""), limit: nil)
    end

    def test_request_body_capture_skips_disallowed_content_type
      assert_empty Julewire::Rack::Capture::RequestBody.call(
        double_content_type("text/plain"),
        content_types: true,
        limit: 10,
        mode: Julewire::Rack::Capture::Settings::STRING_BODY
      )
    end

    def test_request_body_capture_contains_unreadable_body
      assert_empty Julewire::Rack::Capture::RequestBody.call(
        double_body(Object.new),
        content_types: true,
        limit: 10,
        mode: Julewire::Rack::Capture::Settings::STRING_BODY
      )
    end

    def test_request_body_capture_contains_raw_post_failure
      assert_empty Julewire::Rack::Capture::RequestBody.call(
        double_raw_post_error,
        content_types: true,
        limit: nil,
        mode: Julewire::Rack::Capture::Settings::STRING_BODY
      )
    end

    def test_request_body_capture_truncates_to_empty_when_limit_is_zero
      assert_equal(
        { "request_body" => "", "request_body_bytes" => 1, "request_body_truncated" => true },
        stringify_keys(
          Julewire::Rack::Capture::RequestBody.call(
            double_body(StringIO.new("ignored"), content_length: "nope"),
            content_types: true,
            limit: 0,
            mode: Julewire::Rack::Capture::Settings::STRING_BODY
          )
        )
      )
    end

    def test_request_body_capture_json_mode_parses_without_emitting_raw_body
      request = json_request('{"ok":true,"items":[{"id":1}]}')

      fields = request_body_fields(
        request,
        limit: nil,
        mode: Julewire::Rack::Capture::Settings::JSON_BODY
      )

      assert fields.fetch(:request_body_json).fetch("ok")
      assert_equal [{ "id" => 1 }], fields.fetch(:request_body_json).fetch("items")
      assert_equal 30, fields.fetch(:request_body_bytes)
      refute fields.fetch(:request_body_truncated)
      refute_includes fields, :request_body
    end

    def test_request_body_capture_json_mode_skips_truncated_body
      truncated_request = json_request('{"ok":true}')

      truncated = request_body_fields(
        truncated_request,
        limit: 2,
        mode: Julewire::Rack::Capture::Settings::JSON_BODY
      )

      assert_equal 11, truncated.fetch(:request_body_bytes)
      assert truncated.fetch(:request_body_truncated)
      refute_includes truncated, :request_body
      refute_includes truncated, :request_body_json
    end

    def test_request_body_capture_json_mode_reports_parse_errors
      invalid_request = json_request("not-json")

      invalid = request_body_fields(
        invalid_request,
        limit: nil,
        mode: Julewire::Rack::Capture::Settings::JSON_BODY
      )

      assert_equal "JSON::ParserError", invalid.fetch(:request_body_parse_error)
      refute_includes invalid, :request_body
    end

    def test_request_body_capture_restores_stream_when_read_fails
      body = failing_body_stream

      assert_empty Julewire::Rack::Capture::RequestBody.call(
        double_body(body),
        content_types: true,
        limit: 10,
        mode: Julewire::Rack::Capture::Settings::STRING_BODY
      )
      assert_equal 1, body.rewind_count
    end

    def test_response_body_capture_edges
      response = response_double(body: "hello", stream: ["hello"], headers: { "content-type" => "application/json" })

      assert_equal(
        { "response_body" => "he", "response_body_bytes" => 5, "response_body_truncated" => true },
        stringify_keys(response_body_fields(response, limit: 2))
      )
      assert_equal(
        { "response_body" => "", "response_body_bytes" => 5, "response_body_truncated" => true },
        stringify_keys(response_body_fields(response, limit: 0))
      )

      file_stream = Object.new
      file_stream.define_singleton_method(:to_path) { "/tmp/file" }

      assert_empty Julewire::Rack::Capture::BufferedResponseBody.call(
        response_double(body: "hello", stream: file_stream), content_types: true, limit: 10
      )
      assert_empty Julewire::Rack::Capture::BufferedResponseBody.call(
        response_double(body: "hello", stream: Object.new), content_types: true, limit: 10
      )
      assert_empty Julewire::Rack::Capture::BufferedResponseBody.call(
        response_double(body: Object.new, stream: []), content_types: true, limit: 10
      )
      assert_empty Julewire::Rack::Capture::BufferedResponseBody.call(Object.new, content_types: true, limit: 10)
      assert_equal(
        { "response_body" => "hello", "response_body_bytes" => 5, "response_body_truncated" => false },
        stringify_keys(response_body_fields(response, limit: nil))
      )
    end

    def test_response_body_capture_reuses_unlimited_single_string_part
      body = "hello"
      response = response_double(body: "ignored", stream: [body], headers: { "content-type" => "application/json" })

      fields = response_body_fields(response, limit: nil)

      assert_same body, fields.fetch(:response_body)
      assert_equal 5, fields.fetch(:response_body_bytes)
      refute fields.fetch(:response_body_truncated)
    end

    def test_response_body_capture_json_mode_parses_without_emitting_raw_body
      response = response_double(
        body: "ignored",
        stream: ['{"ok":true,', '"items":[1,2]}'],
        headers: { "content-type" => "application/json" }
      )

      fields = response_body_fields(
        response,
        limit: nil,
        mode: Julewire::Rack::Capture::Settings::JSON_BODY
      )

      assert fields.fetch(:response_body_json).fetch("ok")
      assert_equal [1, 2], fields.fetch(:response_body_json).fetch("items")
      assert_equal 25, fields.fetch(:response_body_bytes)
      refute fields.fetch(:response_body_truncated)
      refute_includes fields, :response_body
    end

    def test_response_body_capture_json_mode_skips_truncated_body
      truncated_response = response_double(
        body: "ignored",
        stream: ['{"ok":true}'],
        headers: { "content-type" => "application/json" }
      )

      truncated = response_body_fields(
        truncated_response,
        limit: 2,
        mode: Julewire::Rack::Capture::Settings::JSON_BODY
      )

      assert_equal 11, truncated.fetch(:response_body_bytes)
      assert truncated.fetch(:response_body_truncated)
      refute_includes truncated, :response_body
      refute_includes truncated, :response_body_json
    end

    def test_response_body_capture_json_mode_reports_parse_errors
      invalid_response = response_double(
        body: "ignored",
        stream: ["not-json"],
        headers: { "content-type" => "application/json" }
      )

      invalid = response_body_fields(
        invalid_response,
        limit: nil,
        mode: Julewire::Rack::Capture::Settings::JSON_BODY
      )

      assert_equal "JSON::ParserError", invalid.fetch(:response_body_parse_error)
      refute_includes invalid, :response_body
    end

    def test_response_body_capture_reads_buffered_parts_without_joining_response_body
      response = response_double_with_raising_body(["hello", " world"])

      assert_equal(
        { "response_body" => "hello w", "response_body_bytes" => 11, "response_body_truncated" => true },
        stringify_keys(response_body_fields(response, limit: 7))
      )
    end

    def test_response_body_capture_contains_stream_to_ary_failures
      stream = Object.new
      stream.define_singleton_method(:to_ary) { raise "to_ary failed" }
      response = response_double_with_raising_body(stream)

      assert_empty Julewire::Rack::Capture::BufferedResponseBody.call(response, content_types: true, limit: 10)
    end

    private

    def json_header = "application/json; charset=utf-8"

    def json_request(body, content_type: "application/json")
      ::Rack::Request.new(
        ::Rack::MockRequest.env_for(
          "/json",
          method: "POST",
          input: StringIO.new(body),
          "CONTENT_TYPE" => content_type,
          "CONTENT_LENGTH" => body.bytesize.to_s
        )
      )
    end

    def request_body_fields(request, mode: Julewire::Rack::Capture::Settings::STRING_BODY, **)
      Julewire::Rack::Capture::RequestBody.call(request, content_types: true, mode: mode, **)
    end

    def response_body_fields(response, **)
      Julewire::Rack::Capture::BufferedResponseBody.call(response, content_types: true, **)
    end

    def double_content_type(value)
      double_methods(content_type: value)
    end

    def double_media_type(value)
      double_methods(media_type: value)
    end

    def double_media_type_with_fallback(media_type, content_type)
      double_methods(media_type: media_type, content_type: content_type)
    end

    def double_mime_type(value)
      double_methods(content_mime_type: value)
    end

    def double_mime_type_with_fallback(mime_type, content_type)
      double_methods(content_mime_type: mime_type, content_type: content_type)
    end

    def double_methods(method_values)
      Object.new.tap do |object|
        method_values.each do |method_name, value|
          object.define_singleton_method(method_name) { value }
        end
      end
    end

    def double_get_header(value)
      Object.new.tap do |object|
        object.define_singleton_method(:get_header) { |_key| value }
      end
    end

    def double_get_header_for(values)
      Object.new.tap do |object|
        object.define_singleton_method(:get_header) { values[it] }
      end
    end

    def double_raising_content_type
      Object.new.tap do |object|
        object.define_singleton_method(:content_type) { raise "content type failed" }
      end
    end

    def object_stringified_as(value)
      Object.new.tap do |object|
        object.define_singleton_method(:to_s) { value }
      end
    end

    def string_like(value)
      Object.new.tap do |object|
        object.define_singleton_method(:to_str) { value }
      end
    end

    def double_body(body, content_length: nil)
      Object.new.tap do |object|
        object.define_singleton_method(:content_type) { "application/json" }
        object.define_singleton_method(:body) { body }
        object.define_singleton_method(:content_length) { content_length }
      end
    end

    def double_body_with_header_length(body, content_length)
      Object.new.tap do |object|
        object.define_singleton_method(:content_type) { "application/json" }
        object.define_singleton_method(:body) { body }
        object.define_singleton_method(:get_header) { it == "CONTENT_LENGTH" ? content_length : nil }
      end
    end

    def double_raw_post_with_body_stream(raw_post:, content_length:, body:)
      Object.new.tap do |object|
        object.define_singleton_method(:content_type) { "application/json" }
        object.define_singleton_method(:raw_post) { raw_post.respond_to?(:call) ? raw_post.call : raw_post }
        object.define_singleton_method(:body) { body }
        object.define_singleton_method(:content_length) { content_length }
      end
    end

    def double_body_with_content_length_and_header(body, content_length:, header_length:, raw_post:)
      Object.new.tap do |object|
        object.define_singleton_method(:content_type) { "application/json" }
        object.define_singleton_method(:raw_post) { raw_post }
        object.define_singleton_method(:body) { body }
        object.define_singleton_method(:content_length) { content_length }
        object.define_singleton_method(:get_header) { it == "CONTENT_LENGTH" ? header_length : nil }
      end
    end

    def double_raw_post_error
      Object.new.tap do |object|
        object.define_singleton_method(:content_type) { "application/json" }
        object.define_singleton_method(:raw_post) { raise "raw post failed" }
      end
    end

    def raising_read_stream
      Object.new.tap do |object|
        object.define_singleton_method(:read) { |_limit = nil| raise "body stream should not be read" }
      end
    end

    def limit_tracking_stream(body)
      Class.new(StringIO) do
        attr_reader :limits

        def initialize(value)
          super
          @limits = []
        end

        def read(limit = nil, outbuf = nil)
          @limits << limit
          super
        end
      end.new(body)
    end

    def no_position_stream(body)
      Object.new.tap do |object|
        object.define_singleton_method(:read) { |_limit = nil| body }
        object.define_singleton_method(:rewind) { nil }
      end
    end

    def no_position_writer_stream(body)
      Class.new do
        attr_reader :assigned_positions

        def initialize(value)
          @value = value
          @assigned_positions = []
        end

        def read(_limit = nil) = @value
        def rewind = nil

        def pos=(value)
          @assigned_positions << value
        end
      end.new(body)
    end

    def no_rewind_position_stream(body)
      Class.new do
        attr_accessor :pos

        def initialize(value)
          @value = value
          @pos = 0
        end

        def read(_limit = nil) = @value
      end.new(body)
    end

    def failing_position_restore_stream(body)
      Class.new do
        attr_reader :pos

        def initialize(value)
          @value = value
          @pos = 0
        end

        def read(_limit = nil) = @value
        def rewind = nil

        def pos=(_value)
          raise "position restore failed"
        end
      end.new(body)
    end

    def failing_body_stream
      Class.new do
        attr_reader :rewind_count

        def initialize
          @rewind_count = 0
        end

        def read(_limit = nil)
          raise "read failed"
        end

        def rewind
          @rewind_count += 1
        end
      end.new
    end

    def double_headers(headers)
      Object.new.tap do |object|
        object.define_singleton_method(:headers) { headers }
      end
    end

    def response_double(body:, stream:, headers: {})
      Object.new.tap do |response|
        response.define_singleton_method(:stream) { stream }
        response.define_singleton_method(:body) { body }
        response.define_singleton_method(:headers) { headers }
      end
    end

    def response_double_with_raising_body(stream)
      Object.new.tap do |response|
        response.define_singleton_method(:stream) { stream }
        response.define_singleton_method(:body) { raise "body should not be joined" }
        response.define_singleton_method(:headers) { { "content-type" => "application/json" } }
      end
    end

    def stringify_keys(hash)
      hash.transform_keys(&:to_s)
    end
  end
end
