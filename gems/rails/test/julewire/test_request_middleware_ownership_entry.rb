# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestRequestMiddlewareOwnershipEntry < Minitest::Test
    cover "Julewire::Rails::RequestMiddleware#call"
    cover "Julewire::Rails::RequestMiddleware#own_request_error"
    cover "Julewire::Rails::RequestErrorOwnership.clear"

    def test_request_entry_clears_ownership_from_the_previous_request
      output = configure_output
      error = RuntimeError.new("first")
      first_app = lambda do |env|
        env["action_dispatch.exception"] = error
        env["action_dispatch.report_exception"] = true
        [500, {}, []]
      end
      first_middleware = Julewire::Rails::RequestMiddleware.new(first_app)
      second_middleware = Julewire::Rails::RequestMiddleware.new(->(_env) { [200, {}, []] })
      subscriber = Julewire::Rails::Subscribers::Error.new

      call_and_close(first_middleware, rails_exception_env_for("/first"))
      call_and_close(second_middleware, ::Rack::MockRequest.env_for("/second"))
      report_dispatch_error(subscriber, error, path: "/first")

      rails_error = parse_records(output).find { it["event"] == "rails.error" }

      refute_nil rails_error
      assert_equal "first", rails_error.dig("error", "message")
    end

    def test_request_without_summary_does_not_claim_request_error_ownership
      output = configure_output
      settings = Julewire::Rails::Configuration.new
      settings.request_summary = false
      error = RuntimeError.new("rendered")
      app = lambda do |env|
        env["action_dispatch.exception"] = error
        [500, {}, []]
      end
      middleware = Julewire::Rails::RequestMiddleware.new(app, settings)
      env = ::Rack::MockRequest.env_for("/no-summary-error")

      call_and_close(middleware, env)

      assert_empty parse_records(output)
      assert_nil env[Julewire::Rails::RequestMiddleware::REQUEST_ERROR_ENV_KEY]
      assert_false Julewire::Rails::RequestErrorOwnership.consume?(error)
    ensure
      Julewire::Rails::RequestErrorOwnership.clear
    end
  end
end
