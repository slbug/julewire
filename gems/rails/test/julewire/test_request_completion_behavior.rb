# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestRequestCompletion < Minitest::Test
    cover "Julewire::Rails::RequestLifecycle#start_execution!"
    cover Julewire::Rails::RequestCompletion
    cover "Julewire::Rails::RequestCompletion#finish_completion"

    def test_request_summary_false_keeps_request_execution_context_and_carry
      captured = []
      configure_output(captured: captured)
      settings = Julewire::Rails::Configuration.new
      settings.request_summary = false
      settings.carry_request_headers = %w[traceparent]
      middleware = Julewire::Rails::RequestMiddleware.new(emitting_app, settings)

      call_and_close(
        middleware,
        ::Rack::MockRequest.env_for(
          "/orders",
          "HTTP_X_REQUEST_ID" => "req-1",
          "HTTP_TRACEPARENT" => "00-06796866738c859f2f19b7cfb3214824-000000000000004a-01"
        )
      )

      assert_equal 1, captured.length

      point = captured.fetch(0)

      assert_equal "inside", point.fetch(:message)
      assert_equal "request", point.dig(:execution, :type)
      assert_equal "req-1", point.dig(:context, :request_id)
      assert_equal(
        { "traceparent" => "00-06796866738c859f2f19b7cfb3214824-000000000000004a-01" },
        stringified_carry_headers(point)
      )
    end

    def test_request_summary_can_finish_from_rack_response_finished_callback
      output = configure_output
      callbacks = []
      env = ::Rack::MockRequest.env_for("/finished", "HTTP_X_REQUEST_ID" => "req-finished")
      env["rack.response_finished"] = callbacks
      middleware = Julewire::Rails::RequestMiddleware.new(->(_env) { [202, {}, []] })

      status, headers, body = middleware.call(env)

      assert_empty parse_records(output)

      callbacks.fetch(0).call(env, status, headers, nil)
      body.close

      summary = parse_records(output).fetch(0)

      assert_equal 202, summary_status(summary)
      assert_equal "closed", completion(summary)
      assert_equal 1, parse_records(output).length
    end

    def test_request_completion_attach_mutates_mutable_response_body
      finishes = []
      instrumentation_finishes = []
      instrumenter_handle = Object.new
      instrumenter_handle.define_singleton_method(:finish) { instrumentation_finishes << :finish }
      completion = request_completion(
        execution_handle: completion_probe_handle(finishes),
        instrumenter_handle: instrumenter_handle
      )
      body = ["response-body"]
      response = [204, { "content-type" => "text/plain" }, body]

      returned = completion.attach(response)

      assert_same response, returned
      refute_same body, response.fetch(2)
      assert_instance_of Julewire::Rails::ContextBodyProxy, response.fetch(2)
      assert_equal ["response-body"], response.fetch(2).each.to_a

      response.fetch(2).close

      assert_equal :closed, finishes.fetch(0).fetch(:reason)
      assert_equal({ rails: { completion: "closed" } }, finishes.fetch(0).fetch(:attributes))
      assert_true finishes.fetch(0).fetch(:in_context)
      assert_equal [:finish], instrumentation_finishes
    end

    def test_request_completion_attach_returns_new_response_for_frozen_response
      finishes = []
      completion = request_completion(execution_handle: completion_probe_handle(finishes))
      body = []
      headers = { "content-type" => "text/plain" }
      response = [201, headers, body].freeze

      returned = completion.attach(response)

      refute_same response, returned
      assert_equal [201, headers], returned.first(2)
      assert_same body, response.fetch(2)
      assert_instance_of Julewire::Rails::ContextBodyProxy, returned.fetch(2)

      returned.fetch(2).close

      assert_equal :closed, finishes.fetch(0).fetch(:reason)
      assert_true finishes.fetch(0).fetch(:in_context)
    end

    def test_request_completion_finishes_once_when_response_finished_and_body_close_both_run
      finishes = []
      callbacks = []
      completion = request_completion(
        execution_handle: completion_probe_handle(finishes),
        env: { "rack.response_finished" => callbacks }
      )
      returned = completion.attach([200, {}, []])

      callbacks.fetch(0).call(nil, nil, nil, nil)
      returned.fetch(2).close

      assert_equal 1, finishes.length
      assert_equal :closed, finishes.fetch(0).fetch(:reason)
      assert_equal({ rails: { completion: "closed" } }, finishes.fetch(0).fetch(:attributes))
      assert_true finishes.fetch(0).fetch(:in_context)
    end

    def test_request_completion_ignores_non_appendable_response_finished_container
      finishes = []
      completion = request_completion(
        execution_handle: completion_probe_handle(finishes),
        env: { "rack.response_finished" => Object.new }
      )
      returned = completion.attach([200, {}, []])

      returned.fetch(2).close

      assert_equal 1, finishes.length
      assert_equal :closed, finishes.fetch(0).fetch(:reason)
      assert_true finishes.fetch(0).fetch(:in_context)
    end

    def test_request_completion_response_finished_error_finishes_with_error_details
      finishes = []
      callbacks = []
      completion = request_completion(
        execution_handle: completion_probe_handle(finishes),
        env: { "rack.response_finished" => callbacks }
      )
      error = RuntimeError.new("stream failed")
      completion.attach([200, {}, []])

      callbacks.fetch(0).call(nil, nil, nil, error)

      finish = finishes.fetch(0)

      assert_equal :error, finish.fetch(:reason)
      assert_true finish.fetch(:in_context)
      assert_same error, finish.fetch(:error)
      assert_equal(
        { rails: { completion: "error", completion_error_class: "RuntimeError" } },
        finish.fetch(:attributes)
      )
    end

    def test_request_completion_owned_request_error_finishes_with_error_severity
      finishes = []
      error = RuntimeError.new("rendered")
      completion = request_completion(
        execution_handle: completion_probe_handle(finishes),
        request_error: { error: error, severity: :fatal }
      )
      returned = completion.attach([200, {}, []])

      returned.fetch(2).close

      finish = finishes.fetch(0)

      assert_equal :error, finish.fetch(:reason)
      assert_true finish.fetch(:in_context)
      assert_same error, finish.fetch(:error)
      assert_equal :fatal, finish.fetch(:severity)
      assert_equal({ rails: { completion: "error" } }, finish.fetch(:attributes))
    end

    def test_request_completion_disabled_timeout_does_not_read_request_context
      finishes = []
      request = Object.new
      request.define_singleton_method(:path) { raise "path should not be read" }
      request.define_singleton_method(:get_header) { |_name| raise "headers should not be read" }
      completion = request_completion(
        execution_handle: completion_probe_handle(finishes),
        request: request
      )

      returned = completion.attach([200, {}, []])
      returned.fetch(2).close

      assert_equal :closed, finishes.fetch(0).fetch(:reason)
    end

    def test_request_completion_timeout_warning_contains_warn_failures
      completion = request_completion(execution_handle: completion_probe_handle([]))

      result = with_overridden_singleton_method(Julewire, :warn, proc { |_record| raise "warn failed" }) do
        completion.__send__(:emit_completion_timeout_warning, 0.01, {})
      end

      assert_nil result
    end

    def test_request_summary_can_finish_with_response_finished_error
      output = configure_output
      callbacks = []
      env = rails_exception_env_for("/finished-error")
      env["rack.response_finished"] = callbacks
      middleware = Julewire::Rails::RequestMiddleware.new(->(_env) { [200, {}, []] })

      status, headers, body = middleware.call(env)
      callbacks.fetch(0).call(env, status, headers, RuntimeError.new("stream failed"))
      body.close

      summary = parse_records(output).fetch(0)

      assert_equal "error", summary.fetch("severity")
      assert_equal "error", completion(summary)
      assert_equal "RuntimeError", summary.dig("attributes", "rails", "completion_error_class")
      assert_equal "RuntimeError", summary.dig("error", "class")
      assert_equal 1, parse_records(output).length
    end

    def test_request_summary_timeout_emits_warning_and_keeps_late_close_summary
      output = configure_output
      settings = Julewire::Rails::Configuration.new
      settings.request_summary_timeout = 0.01
      middleware = Julewire::Rails::RequestMiddleware.new(->(_env) { [200, {}, []] }, settings)

      env = ::Rack::MockRequest.env_for("/timeout", "HTTP_X_REQUEST_ID" => "timeout-1")
      _status, _headers, body = middleware.call(env)
      warning = wait_for_records(output, count: 1).fetch(0)
      body.close
      summary = wait_for_records(output, count: 2).find { it["kind"] == "summary" }

      assert_timeout_warning(warning, request_id: "timeout-1", path: "/timeout")
      assert_equal "closed", completion(summary)
      assert_equal 2, parse_records(output).length
    end

    def test_request_summary_timeout_runs_even_when_response_finished_callback_exists
      output = configure_output
      settings = Julewire::Rails::Configuration.new
      settings.request_summary_timeout = 0.01
      callbacks = []
      middleware = Julewire::Rails::RequestMiddleware.new(->(_env) { [200, {}, []] }, settings)

      env = ::Rack::MockRequest.env_for("/timeout-finished", "HTTP_X_REQUEST_ID" => "timeout-finished-1")
      env["rack.response_finished"] = callbacks
      _status, _headers, body = middleware.call(env)
      warning = wait_for_records(output, count: 1).fetch(0)
      body.close

      assert_equal 1, callbacks.length
      assert_timeout_warning(warning, request_id: "timeout-finished-1", path: "/timeout-finished")
    end

    def test_request_summary_timeout_omits_absent_request_id_from_warning_context
      output = configure_output
      settings = Julewire::Rails::Configuration.new
      settings.request_summary_timeout = 0.01049
      request = Object.new
      request.define_singleton_method(:path) { "/timeout-no-request-id" }
      request.define_singleton_method(:get_header) { |_name| nil }
      completion = request_completion(
        execution_handle: completion_probe_handle([]),
        configuration: settings,
        request: request
      )

      body = completion.attach([200, {}, []]).fetch(2)
      warning = wait_for_records(output, count: 1).fetch(0)
      body.close

      assert_equal "request.completion_timeout", warning.fetch("event")
      assert_equal "Rails", warning.fetch("logger")
      assert_equal "rails", warning.fetch("source")
      assert_equal 10, warning.dig("attributes", "rails", "completion_timeout_ms")
      assert_equal "/timeout-no-request-id", warning.dig("context", "path")
      assert_false warning.fetch("context").key?("request_id")
    end

    def test_request_summary_timeout_can_be_disabled
      output = configure_output
      settings = Julewire::Rails::Configuration.new
      settings.request_summary_timeout = nil
      middleware = Julewire::Rails::RequestMiddleware.new(->(_env) { [200, {}, []] }, settings)

      _status, _headers, body = middleware.call(::Rack::MockRequest.env_for("/timeout-disabled"))
      body.close

      summary = parse_records(output).fetch(0)

      assert_equal "request.completed", summary.fetch("event")
      assert_equal "closed", completion(summary)
      assert_equal 1, parse_records(output).length
    end

    def test_request_summary_timeout_can_emit_warning_without_request_context
      output = configure_output
      settings = Julewire::Rails::Configuration.new
      settings.request_context = false
      settings.request_summary_timeout = 0.01051
      middleware = Julewire::Rails::RequestMiddleware.new(->(_env) { [200, {}, []] }, settings)

      _status, _headers, body = middleware.call(::Rack::MockRequest.env_for("/timeout-no-context"))
      warning = wait_for_records(output, count: 1).fetch(0)
      body.close

      assert_equal "request.completion_timeout", warning.fetch("event")
      assert_equal "Rails", warning.fetch("logger")
      assert_equal "rails", warning.fetch("source")
      assert_equal 11, warning.dig("attributes", "rails", "completion_timeout_ms")
      assert_false warning.key?("context")
      assert_equal "request.completed", parse_records(output).find { it["kind"] == "summary" }.fetch("event")
    end

    def test_request_summary_timeout_is_cancelled_on_close
      output = configure_output
      settings = Julewire::Rails::Configuration.new
      settings.request_summary_timeout = 0.01
      queue = Queue.new
      middleware = Julewire::Rails::RequestMiddleware.new(->(_env) { [200, {}, []] }, settings)

      _status, _headers, body = middleware.call(::Rack::MockRequest.env_for("/closed"))
      body.close
      Julewire::Rails::RequestSummaryTimeoutScheduler.schedule(0.02) { queue << :sentinel }

      assert_equal :sentinel, Timeout.timeout(1) { queue.pop }

      summary = parse_records(output).fetch(0)

      assert_equal "closed", completion(summary)
      assert_equal 1, parse_records(output).length
    end

    def test_request_summary_timeout_keeps_owned_request_error
      output = configure_output
      error = RuntimeError.new("rendered timeout")
      middleware = Julewire::Rails::RequestMiddleware.new(rendered_exception_app(error), timeout_settings)

      env = rails_exception_env_for("/timeout-error").tap do |rack_env|
        rack_env["HTTP_X_REQUEST_ID"] = "timeout-error-1"
      end
      _status, _headers, body = middleware.call(env)
      warning = wait_for_records(output, count: 1).fetch(0)
      body.close
      summary = wait_for_records(output, count: 2).find { it["kind"] == "summary" }

      assert_timeout_warning(warning, request_id: "timeout-error-1", path: "/timeout-error")
      assert_equal "error", summary.fetch("severity")
      assert_equal "error", completion(summary)
      assert_equal "RuntimeError", summary.dig("attributes", "rails", "error_class")
      assert_equal "RuntimeError", summary.dig("error", "class")
      assert_equal 2, parse_records(output).length
    end

    def test_request_completion_finish_instrumentation_tolerates_missing_handle
      assert_nil Julewire::Rails::RequestCompletion.finish_instrumentation(nil)
    end

    def test_request_completion_finish_instrumentation_finishes_handle_and_flushes_logs
      calls = []
      handle = Object.new
      handle.define_singleton_method(:finish) do
        calls << :finish
        :finished
      end

      result = with_overridden_singleton_method(::ActiveSupport::LogSubscriber, :flush_all!, proc {
        calls << :flush
      }) do
        Julewire::Rails::RequestCompletion.finish_instrumentation(handle)
      end

      assert_equal :finished, result
      assert_equal %i[finish flush], calls
    end

    def test_request_completion_finish_instrumentation_flushes_top_level_log_subscribers
      calls = []
      shadow = Module.new do
        const_set(:LogSubscriber, Module.new do
          def self.flush_all! = raise "nested ActiveSupport must not be used"
        end)
      end

      with_temporary_constant(Julewire::Rails::RequestCompletion, :ActiveSupport, shadow) do
        with_overridden_singleton_method(::ActiveSupport::LogSubscriber, :flush_all!, proc {
          calls << :flush
        }) do
          Julewire::Rails::RequestCompletion.finish_instrumentation(nil)
        end
      end

      assert_equal [:flush], calls
    end

    def test_request_completion_finish_instrumentation_contains_finish_and_flush_failures
      calls = []
      handle = Object.new
      handle.define_singleton_method(:finish) do
        calls << :finish
        raise "finish failed"
      end

      result = with_overridden_singleton_method(::ActiveSupport::LogSubscriber, :flush_all!, proc {
        calls << :flush
        raise "flush failed"
      }) do
        Julewire::Rails::RequestCompletion.finish_instrumentation(handle)
      end

      assert_nil result
      assert_equal %i[finish flush], calls
    end

    private

    def assert_timeout_warning(warning, request_id:, path:, timeout_ms: 10)
      assert_equal "request.completion_timeout", warning.fetch("event")
      assert_equal "Rails", warning.fetch("logger")
      assert_equal "rails", warning.fetch("source")
      assert_equal request_id, warning.dig("context", "request_id")
      assert_equal path, warning.dig("context", "path")
      assert_equal timeout_ms, warning.dig("attributes", "rails", "completion_timeout_ms")
    end

    def request_completion(
      execution_handle:,
      configuration: nil,
      instrumenter_handle: nil,
      env: {},
      request: nil,
      request_error: nil
    )
      configuration ||= Julewire::Rails::Configuration.new.tap { it.request_summary_timeout = nil }
      request ||= action_dispatch_request("/request-completion")
      Julewire::Rails::RequestCompletion.new(
        configuration: configuration,
        execution_handle: execution_handle,
        instrumenter_handle: instrumenter_handle,
        env: env,
        request: request,
        request_error: request_error
      )
    end

    def completion_probe_handle(finishes)
      inside_context = false
      Object.new.tap do |handle|
        handle.define_singleton_method(:with_context) do |&block|
          inside_context = true
          block.call
        ensure
          inside_context = false
        end
        handle.define_singleton_method(:finish) do |**fields|
          finishes << fields.merge(in_context: inside_context)
        end
      end
    end

    def completion(record)
      record.dig("attributes", "julewire.completion")
    end

    def summary_status(record)
      record.dig("attributes", "rails", "status") || record.dig("attributes", "http.response.status_code")
    end

    def wait_for_records(output, count:)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.5
      records = parse_records(output)
      while records.length < count && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        sleep 0.005
        records = parse_records(output)
      end
      records
    end

    def timeout_settings
      Julewire::Rails::Configuration.new.tap { it.request_summary_timeout = 0.01 }
    end

    def rendered_exception_app(error)
      lambda do |env|
        env["action_dispatch.exception"] = error
        [503, {}, []]
      end
    end
  end
end
