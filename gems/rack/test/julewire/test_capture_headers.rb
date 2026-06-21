# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestCaptureHeaders < Minitest::Test
    cover Julewire::Rack::Capture::Headers
    cover Julewire::Rack::Capture::HeaderSelection

    def test_request_broad_capture_normalizes_and_filters_headers
      headers = Julewire::Rack::Capture::Headers.request(
        request_double(
          "CONTENT_TYPE" => "application/json",
          "CONTENT_LENGTH" => 12,
          "HTTP_ACCEPT" => ["text/html", "application/json"],
          "HTTP_AUTHORIZATION" => "secret",
          "rack.input" => "ignored"
        ),
        selector: true
      )

      assert_equal(
        {
          "content-type" => "application/json",
          "content-length" => "12",
          "accept" => "text/html, application/json"
        },
        headers
      )
    end

    def test_request_explicit_capture_can_include_sensitive_headers
      headers = Julewire::Rack::Capture::Headers.request(
        request_double(
          "HTTP_ACCEPT" => "application/json",
          "HTTP_AUTHORIZATION" => "secret",
          "HTTP_X_API_KEY" => "key"
        ),
        selector: %w[authorization x-api-key]
      )

      assert_equal({ "authorization" => "secret", "x-api-key" => "key" }, headers)
      assert_equal(
        { "accept" => "application/json" },
        Julewire::Rack::Capture::Headers.request(
          request_double("HTTP_ACCEPT" => "application/json"),
          selector: "accept"
        )
      )
    end

    def test_response_broad_capture_normalizes_and_filters_headers
      headers = Julewire::Rack::Capture::Headers.response(
        {
          "X_Response_ID" => 123,
          "Set-Cookie" => "secret",
          "X-Multi" => %w[a b]
        },
        selector: true
      )

      assert_equal({ "x-response-id" => "123", "x-multi" => "a, b" }, headers)
    end

    def test_response_explicit_capture_can_include_sensitive_headers
      headers = Julewire::Rack::Capture::Headers.response(
        { "X-Response-ID" => "res-1", "Set-Cookie" => "secret" },
        selector: %w[set-cookie]
      )

      assert_equal({ "set-cookie" => "secret" }, headers)
    end

    def test_empty_inputs_and_selectors_do_not_capture
      capture = Julewire::Rack::Capture::Headers

      assert_equal({}, capture.request(Object.new, selector: true))
      assert_equal({}, capture.request(request_double(Object.new), selector: true))
      assert_equal({}, capture.response(Object.new, selector: true))
      assert_equal({}, capture.request(request_double("HTTP_ACCEPT" => "application/json"), selector: false))
      assert_equal({}, capture.response({ "X-Response-ID" => "res-1" }, selector: nil))
      assert_nil Julewire::Rack::Capture::HeaderSelection.build(nil)
      assert_nil Julewire::Rack::Capture::HeaderSelection.build(false)
      assert_includes Julewire::Rack::Capture::HeaderSelection.build(true), "accept"
    end

    def test_request_name_normalization
      capture = Julewire::Rack::Capture::Headers

      assert_equal(
        {
          "content-type" => "application/json",
          "content-length" => "12",
          "x-request-id" => "req-1",
          "x-object" => "object"
        },
        capture.request(
          request_double(
            "CONTENT_TYPE" => "application/json",
            "CONTENT_LENGTH" => 12,
            "HTTP_X_REQUEST_ID" => "req-1",
            object_stringified_as("HTTP_X_OBJECT") => "object",
            "rack.input" => "ignored"
          ),
          selector: %w[content-type content-length x-request-id x-object rack.input]
        )
      )
    end

    def test_response_name_normalization
      capture = Julewire::Rack::Capture::Headers

      assert_equal(
        { "x-request-id" => "res-1", "x-object" => "object" },
        capture.response(
          {
            "X_Request_ID" => "res-1",
            object_stringified_as("X_OBJECT") => "object"
          },
          selector: %w[x-request-id x-object]
        )
      )
    end

    def test_header_value_formats_array_subclasses
      array = Class.new(Array).new(%w[a b])

      assert_equal(
        { "accept" => "a, b" },
        Julewire::Rack::Capture::Headers.request(request_double("HTTP_ACCEPT" => array), selector: %w[accept])
      )
    end

    private

    def request_double(env)
      Object.new.tap do |request|
        request.define_singleton_method(:env) { env }
      end
    end

    def object_stringified_as(value)
      Object.new.tap do |object|
        object.define_singleton_method(:to_s) { value }
      end
    end
  end
end
