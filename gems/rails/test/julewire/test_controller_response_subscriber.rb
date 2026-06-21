# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestControllerResponseSubscriber < Minitest::Test
    cover Julewire::Rails::Subscribers::ControllerResponse

    def test_controller_response_subscriber_captures_response_body_from_notification_payload
      response = ActionDispatch::Response.create(200, { "content-type" => "application/json" }, ["hello", " world"])
      summary = capture_controller_response_summary(response, limit: nil)

      assert_equal "hello world", summary.dig("attributes", "rails", "response_body")
      assert_equal 11, summary.dig("attributes", "rails", "response_body_bytes")
      refute summary.dig("attributes", "rails", "response_body_truncated")
    end

    def test_controller_response_subscriber_caps_response_body
      response = ActionDispatch::Response.create(200, { "content-type" => "application/json" }, ["hello world"])
      summary = capture_controller_response_summary(response, limit: 5)

      assert_equal "hello", summary.dig("attributes", "rails", "response_body")
      assert_equal 11, summary.dig("attributes", "rails", "response_body_bytes")
      assert summary.dig("attributes", "rails", "response_body_truncated")
    end

    def test_controller_response_subscriber_skips_file_response_body
      response = ActionDispatch::Response.create(200, { "content-type" => "application/octet-stream" }, ["ignored"])
      response.send_file(__FILE__)
      summary = capture_controller_response_summary(response)

      refute summary.dig("attributes", "rails").to_h.key?("response_body")
    end

    def test_controller_response_subscriber_skips_unbuffered_response_body
      response = Object.new
      stream = Object.new
      response.define_singleton_method(:stream) { stream }
      response.define_singleton_method(:body) { raise "body should not be read" }
      summary = capture_controller_response_summary(response)

      refute summary.dig("attributes", "rails").to_h.key?("response_body")
    end

    def test_controller_response_subscriber_skips_non_json_response_body_by_default
      response = ActionDispatch::Response.create(200, { "content-type" => "text/plain" }, ["hello"])
      summary = capture_controller_response_summary(response)

      refute summary.dig("attributes", "rails").to_h.key?("response_body")
    end

    def test_controller_response_subscriber_captures_vendor_json_response_body_by_default
      response = ActionDispatch::Response.create(200, { "content-type" => "application/vnd.api+json" }, ["hello"])
      summary = capture_controller_response_summary(response)

      assert_equal "hello", summary.dig("attributes", "rails", "response_body")
    end

    def test_controller_response_subscriber_can_capture_all_response_body_content_types
      response = ActionDispatch::Response.create(200, { "content-type" => "text/plain" }, ["hello"])
      summary = capture_controller_response_summary(response, response_capture: { body_content_types: true })

      assert_equal "hello", summary.dig("attributes", "rails", "response_body")
    end

    def test_controller_subscriber_captures_configured_request_and_response_details
      request = ActionDispatch::Request.new(
        ::Rack::MockRequest.env_for(
          "/orders",
          method: "POST",
          input: "hello world",
          "CONTENT_TYPE" => "application/json",
          "HTTP_TRACEPARENT" => "00-06796866738c859f2f19b7cfb3214824-000000000000004a-01"
        )
      )
      response = ActionDispatch::Response.create(201, { "x-response-id" => "response-1" }, ["ok"])
      summary = capture_controller_summary(
        request: request,
        response: response,
        request_capture: { headers: true, body: true },
        response_capture: { headers: true }
      )

      assert_equal "00-06796866738c859f2f19b7cfb3214824-000000000000004a-01",
                   summary.dig("attributes", "rails", "request_headers", "traceparent")
      assert_equal "hello world", summary.dig("attributes", "rails", "request_body")
      assert_equal 11, summary.dig("attributes", "rails", "request_body_bytes")
      refute summary.dig("attributes", "rails", "request_body_truncated")
      assert_equal "response-1", summary.dig("attributes", "rails", "response_headers", "x-response-id")
      refute summary.fetch("attributes").fetch("rails").key?("response_body")
    end

    def test_controller_subscriber_omits_sensitive_headers_from_broad_capture
      request = ActionDispatch::Request.new(
        ::Rack::MockRequest.env_for("/orders", "HTTP_AUTHORIZATION" => "secret", "HTTP_X_REQUEST_ID" => "req-1")
      )
      response = ActionDispatch::Response.create(200, { "set-cookie" => "secret", "x-response-id" => "res-1" }, [])
      summary = capture_controller_summary(
        request: request,
        response: response,
        request_capture: { headers: true },
        response_capture: { headers: true }
      )

      assert_equal "req-1", summary.dig("attributes", "rails", "request_headers", "x-request-id")
      refute_includes summary.dig("attributes", "rails", "request_headers"), "authorization"
      assert_equal "res-1", summary.dig("attributes", "rails", "response_headers", "x-response-id")
      refute_includes summary.dig("attributes", "rails", "response_headers"), "set-cookie"
    end

    def test_controller_subscriber_bounds_request_body_reads_before_truncating
      input = BoundedBody.new("hello world")
      env = ::Rack::MockRequest.env_for("/orders", method: "POST", input: "", "CONTENT_TYPE" => "application/json")
      env["rack.input"] = input
      env["CONTENT_LENGTH"] = "11"
      request = ActionDispatch::Request.new(env)
      summary = capture_controller_summary(request: request, request_capture: { body: true, body_bytes: 5 })

      assert_equal "hello", summary.dig("attributes", "rails", "request_body")
      assert_equal 11, summary.dig("attributes", "rails", "request_body_bytes")
      assert summary.dig("attributes", "rails", "request_body_truncated")
      assert_equal [6], input.read_lengths
    end

    def test_controller_subscriber_skips_non_json_request_body_by_default
      request = ActionDispatch::Request.new(
        ::Rack::MockRequest.env_for("/orders", method: "POST", input: "hello world", "CONTENT_TYPE" => "text/plain")
      )
      summary = capture_controller_summary(request: request, request_capture: { body: true })

      refute summary.dig("attributes", "rails").to_h.key?("request_body")
    end

    def test_controller_subscriber_captures_vendor_json_request_body_by_default
      request = ActionDispatch::Request.new(
        ::Rack::MockRequest.env_for(
          "/orders",
          method: "POST",
          input: "hello world",
          "CONTENT_TYPE" => "application/problem+json"
        )
      )
      summary = capture_controller_summary(request: request, request_capture: { body: true })

      assert_equal "hello world", summary.dig("attributes", "rails", "request_body")
    end

    def test_controller_subscriber_allows_configured_request_body_content_types
      request = ActionDispatch::Request.new(
        ::Rack::MockRequest.env_for("/orders", method: "POST", input: "hello world", "CONTENT_TYPE" => "text/plain")
      )
      summary = capture_controller_summary(
        request: request,
        request_capture: { body: true, body_content_types: %w[text/plain] }
      )

      assert_equal "hello world", summary.dig("attributes", "rails", "request_body")
    end

    def test_controller_subscriber_allows_header_allowlists
      request = ActionDispatch::Request.new(
        ::Rack::MockRequest.env_for(
          "/orders",
          "HTTP_TRACEPARENT" => "trace",
          "HTTP_AUTHORIZATION" => "secret"
        )
      )
      response = ActionDispatch::Response.create(200, { "x-response-id" => "response-1", "set-cookie" => "secret" }, [])
      summary = capture_controller_summary(
        request: request,
        response: response,
        request_capture: { headers: %w[traceparent authorization] },
        response_capture: { headers: %w[x-response-id set-cookie] }
      )

      assert_equal(
        { "traceparent" => "trace", "authorization" => "secret" },
        summary.dig("attributes", "rails", "request_headers")
      )
      assert_equal(
        { "x-response-id" => "response-1", "set-cookie" => "secret" },
        summary.dig("attributes", "rails", "response_headers")
      )
    end

    def test_controller_response_subscriber_install_can_be_disabled_and_is_idempotent
      settings = disabled_controller_capture_settings

      with_reset_controller_response_subscriber do
        assert_nil Julewire::Rails::Subscribers::ControllerResponse.install!(settings)

        settings.response_capture.headers = true

        assert_controller_response_subscriber_reuses_subscription(settings)

        settings.response_capture.headers = false

        assert_nil Julewire::Rails::Subscribers::ControllerResponse.install!(settings)
        refute_predicate Julewire::Rails::Subscribers::ControllerResponse, :installed?
      end
    end

    def test_controller_response_subscriber_skips_without_current_execution
      output = configure_output
      subscriber = Julewire::Rails::Subscribers::ControllerResponse.new(Julewire::Rails::Configuration.new)

      subscriber.process_action(Event.new(payload: { response: ActionDispatch::Response.create(200, {}, []) }))

      assert_empty parse_records(output)
    end

    def test_controller_response_subscriber_swallows_capture_failures
      output = configure_output
      settings = Julewire::Rails::Configuration.new
      settings.request_capture.headers = true
      subscriber = Julewire::Rails::Subscribers::ControllerResponse.new(settings)
      bad_request = Object.new
      bad_request.define_singleton_method(:env) { raise "bad env" }

      Julewire.with_execution(type: :request, id: "req-1", summary_event: "request.completed") do
        subscriber.process_action(Event.new(payload: { request: bad_request }))
      end

      assert_equal "summary", parse_records(output).fetch(0).fetch("kind")
      assert_equal :degraded, Julewire.health.dig(:process_integrations, :rails, :status)
      assert_equal :controller_response_subscriber,
                   Julewire.health.dig(:process_integrations, :rails, :last_failure, :component)
    end

    class BoundedBody
      attr_reader :read_lengths

      def initialize(value)
        @value = value
        @position = 0
        @read_lengths = []
      end

      def read(length = nil)
        raise "unbounded body read" unless length

        @read_lengths << length
        chunk = @value.byteslice(@position, length)
        @position += chunk&.bytesize || 0
        chunk
      end

      def rewind
        @position = 0
      end

      def pos = @position

      def pos=(value)
        @position = value
      end
    end

    private

    def disabled_controller_capture_settings
      Julewire::Rails::Configuration.new.tap do |settings|
        settings.request_capture.headers = false
        settings.request_capture.body = false
        settings.response_capture.headers = false
        settings.response_capture.body = false
      end
    end

    def with_reset_controller_response_subscriber
      Julewire::Rails::Subscribers::ControllerResponse.reset!
      yield
    ensure
      Julewire::Rails::Subscribers::ControllerResponse.reset!
    end

    def assert_controller_response_subscriber_reuses_subscription(settings)
      first = Julewire::Rails::Subscribers::ControllerResponse.install!(settings)
      next_settings = Julewire::Rails::Configuration.new
      next_settings.request_capture.headers = true
      second = Julewire::Rails::Subscribers::ControllerResponse.install!(next_settings)

      assert_same first, second
      assert_same next_settings, second.instance_variable_get(:@configuration)
    end
  end
end
