# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestRequestAttributes < Minitest::Test
    cover Julewire::Rails::RequestAttributes

    def test_context_and_neutral_request_fields
      request = request_double

      context = Julewire::Rails::RequestAttributes.context_fields(request)
      neutral = Julewire::Rails::RequestAttributes.request(request)

      assert_equal(
        {
          request_id: "req-1",
          http_method: "POST",
          path: "/orders",
          remote_ip: "203.0.113.10"
        },
        context
      )
      assert_equal "POST", neutral.fetch(:"http.request.method")
      assert_equal "https://example.test/orders?token=[FILTERED]", neutral.fetch(:"url.full")
      assert_equal "/orders", neutral.fetch(:"url.path")
      assert_equal "JulewireTest", neutral.fetch(:"user_agent.original")
      assert_equal "203.0.113.10", neutral.fetch(:"client.address")
      assert_equal 1, request.remote_ip_calls

      Julewire::Rails::RequestAttributes.context_fields(request)

      assert_equal 1, request.remote_ip_calls
    end

    def test_request_id_prefers_method_and_falls_back_to_headers
      assert_equal "method-id", Julewire::Rails::RequestAttributes.request_id(request_double(request_id: "method-id"))
      assert_equal(
        "dispatch-id",
        Julewire::Rails::RequestAttributes.request_id(
          request_double(request_id: nil, headers: { "action_dispatch.request_id" => "dispatch-id" })
        )
      )
      assert_equal(
        "header-id",
        Julewire::Rails::RequestAttributes.request_id(
          request_double(request_id: nil, headers: { "HTTP_X_REQUEST_ID" => "header-id" })
        )
      )
    end

    def test_response_summary_includes_rails_and_neutral_status
      summary = Julewire::Rails::RequestAttributes.response_summary(
        request_double,
        201,
        { "content-type" => "application/json" }
      )

      assert_equal 201, summary.dig(:attributes, :rails, :status)
      assert_equal "application/json", summary.dig(:attributes, :rails, :response_content_type)
      assert_equal 201, summary.dig(:neutral, :"http.response.status_code")
      assert_rails_request_fields(summary.dig(:attributes, :rails))
    end

    def test_response_summary_compacts_nil_neutral_status
      summary = Julewire::Rails::RequestAttributes.response_summary(
        request_double,
        nil,
        { "content-type" => "text/plain" }
      )

      refute_includes summary.fetch(:neutral), :"http.response.status_code"
    end

    def test_error_summary_uses_wrapper_values
      summary = Julewire::Rails::RequestAttributes.error_summary(
        request_double,
        RuntimeError.new("boom"),
        status: 503,
        wrapper: response_wrapper(response: true, template: "diagnostics")
      )

      assert_equal "RuntimeError", summary.dig(:attributes, :rails, :error_class)
      assert_equal 503, summary.dig(:attributes, :rails, :status)
      assert summary.dig(:attributes, :rails, :rescue_response)
      assert_equal "diagnostics", summary.dig(:attributes, :rails, :rescue_template)
      assert_equal 503, summary.dig(:neutral, :"http.response.status_code")
      assert_rails_request_fields(summary.dig(:attributes, :rails))
    end

    def test_error_summary_contains_wrapper_failures
      contained = Julewire::Rails::RequestAttributes.error_summary(
        request_double,
        RuntimeError.new("boom"),
        status: 500,
        wrapper: failing_response_wrapper
      )

      refute contained.dig(:attributes, :rails, :rescue_response)
      refute_includes contained.dig(:attributes, :rails), :rescue_template
    end

    def test_rendered_error_summary_uses_rendered_error_metadata
      summary = Julewire::Rails::RequestAttributes.rendered_error_summary(
        request_double,
        {
          error: RuntimeError.new("boom"),
          rescue_response: true,
          rescue_template: "custom"
        },
        status: 500
      )

      assert summary.dig(:attributes, :rails, :rescue_response)
      assert_equal "custom", summary.dig(:attributes, :rails, :rescue_template)
      assert_equal "RuntimeError", summary.dig(:attributes, :rails, :error_class)
      assert_equal 500, summary.dig(:attributes, :rails, :status)
      assert_equal 500, summary.dig(:neutral, :"http.response.status_code")
    end

    def test_reader_failures_are_contained
      request = failing_request_double

      context = Julewire::Rails::RequestAttributes.context_fields(request)
      neutral = Julewire::Rails::RequestAttributes.request(request)

      assert_equal({ http_method: "GET", path: "/edge" }, context)
      assert_equal "GET", neutral.fetch(:"http.request.method")
      refute_includes neutral, :"url.full"
      refute_includes neutral, :"user_agent.original"
      refute_includes neutral, :"client.address"
    end

    def test_remote_ip_uses_cached_env_value_and_handles_request_without_env
      cached_request = request_double(env: { "julewire.rails.remote_ip" => "cached-ip" })
      no_env_request = NoEnvRequest.new

      cached_context = Julewire::Rails::RequestAttributes.context_fields(cached_request)
      no_env_context = Julewire::Rails::RequestAttributes.context_fields(no_env_request)

      assert_equal "cached-ip", cached_context.fetch(:remote_ip)
      assert_equal 0, cached_request.remote_ip_calls
      assert_equal "198.51.100.20", no_env_context.fetch(:remote_ip)
      assert_equal 1, no_env_request.remote_ip_calls
    end

    def test_request_id_uses_headers_when_method_is_absent
      request = Object.new
      request.define_singleton_method(:get_header) do |key|
        { "HTTP_X_REQUEST_ID" => "header-id" }[key]
      end

      assert_equal "header-id", Julewire::Rails::RequestAttributes.request_id(request)
    end

    private

    class RequestDouble
      DEFAULTS = {
        request_id: "req-1",
        headers: {},
        env: {},
        request_method: "POST",
        path: "/orders",
        filtered_path: "/orders?token=[FILTERED]",
        protocol: "https://",
        host_with_port: "example.test",
        remote_ip: "203.0.113.10"
      }.freeze

      attr_reader :env,
                  :host_with_port,
                  :filtered_path,
                  :path,
                  :protocol,
                  :remote_ip_calls,
                  :request_id,
                  :request_method

      def initialize(**options)
        fields = DEFAULTS.merge(options)
        @request_id = fields.fetch(:request_id)
        @headers = {
          "HTTP_USER_AGENT" => "JulewireTest"
        }.merge(fields.fetch(:headers))
        @env = fields.fetch(:env)
        @request_method = fields.fetch(:request_method)
        @path = fields.fetch(:path)
        @filtered_path = fields.fetch(:filtered_path)
        @protocol = fields.fetch(:protocol)
        @host_with_port = fields.fetch(:host_with_port)
        @remote_ip = fields.fetch(:remote_ip)
        @remote_ip_calls = 0
      end

      def get_header(key) = @headers[key]

      def remote_ip
        @remote_ip_calls += 1
        @remote_ip
      end
    end

    class NoEnvRequest
      attr_reader :remote_ip_calls

      def initialize
        @remote_ip_calls = 0
      end

      def request_method = "GET"

      def path = "/no-env"

      def get_header(_key) = nil

      def remote_ip
        @remote_ip_calls += 1
        "198.51.100.20"
      end
    end

    def request_double(**) = RequestDouble.new(**)

    def response_wrapper(response:, template:)
      Object.new.tap do |wrapper|
        wrapper.define_singleton_method(:rescue_response?) { response }
        wrapper.define_singleton_method(:rescue_template) { template }
      end
    end

    def failing_response_wrapper
      Object.new.tap do |wrapper|
        wrapper.define_singleton_method(:rescue_response?) { raise "bad response" }
        wrapper.define_singleton_method(:rescue_template) { raise "bad template" }
      end
    end

    def failing_request_double
      Object.new.tap do |request|
        request.define_singleton_method(:request_method) { "GET" }
        request.define_singleton_method(:path) { "/edge" }
        request.define_singleton_method(:protocol) { raise "bad protocol" }
        request.define_singleton_method(:host_with_port) { raise "bad host" }
        request.define_singleton_method(:filtered_path) { raise "bad path" }
        request.define_singleton_method(:remote_ip) { raise "bad remote ip" }
        request.define_singleton_method(:get_header) { raise "bad header" }
      end
    end

    def assert_rails_request_fields(fields)
      assert_equal "https://example.test/orders?token=[FILTERED]", fields.fetch(:filtered_url)
      assert_equal "/orders?token=[FILTERED]", fields.fetch(:filtered_path)
      assert_equal "POST", fields.fetch(:request_method)
      assert_equal "/orders", fields.fetch(:path)
      assert_equal "JulewireTest", fields.fetch(:user_agent)
    end
  end
end
