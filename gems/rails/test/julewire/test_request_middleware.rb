# frozen_string_literal: true

require "test_helper"
require "timeout"

module Julewire
  class TestRequestMiddleware < Minitest::Test # rubocop:disable Metrics/ClassLength -- Integration surface.
    cover Julewire::Rails::ContextBodyProxy
    cover Julewire::Rails::RequestContext
    cover Julewire::Rails::RequestCompletion
    cover Julewire::Rails::RequestErrorOwnership

    def test_request_middleware_wraps_request_in_execution_summary # rubocop:disable Metrics/MethodLength
      output = configure_output
      middleware = Julewire::Rails::RequestMiddleware.new(emitting_app)

      call_and_close(
        middleware,
        ::Rack::MockRequest.env_for("/orders?token=[FILTERED]", "HTTP_X_REQUEST_ID" => "req-1")
      )

      point, summary = parse_records(output)

      assert_equal "inside", point.fetch("message")
      assert_equal "req-1", point.dig("context", "request_id")
      assert_equal "summary", summary.fetch("kind")
      assert_equal "request.completed", summary.fetch("event")
      assert_equal 200, summary_status(summary)
      refute summary.fetch("payload", {}).key?("request_id")
      assert_equal "req-1", summary.dig("context", "request_id")
      assert_equal(
        {
          "filtered_url" => "http://example.org/orders?token=[FILTERED]",
          "filtered_path" => "/orders?token=[FILTERED]",
          "request_method" => "GET",
          "path" => "/orders",
          "status" => 200
        },
        summary.fetch("attributes").fetch("rails").slice(
          "filtered_url",
          "filtered_path",
          "request_method",
          "path",
          "status"
        )
      )
      assert_julewire_record_source_contract(
        records: [summary],
        event: "request.completed",
        source: "rails",
        kind: "summary"
      )
    end

    def test_request_middleware_satisfies_execution_boundary_contract
      output = StringIO.new
      formatter = :to_h.to_proc

      point, summary, health = assert_julewire_execution_boundary_contract(
        configure: ->(config) { configure_destination(config, formatter: formatter, output: output) },
        exercise: method(:exercise_rails_boundary_contract),
        records: -> { output.string.lines.map { JSON.parse(it) } },
        event_path: %w[event],
        context_path: %w[context],
        carry_path: %w[carry],
        summary_event: "request.completed",
        summary_payload_path: %w[payload]
      )

      assert_equal "point", point.fetch("message")
      assert_equal 200, summary_status(summary)
      assert_equal :ok, health.fetch(:status)
    end

    def test_rails_uses_shared_julewire_integration_spi_contract
      assert_julewire_integration_spi_contract
    end

    def test_request_middleware_captures_configured_carry_headers_on_each_record
      captured = []
      configure_output(captured: captured)
      settings = Julewire::Rails::Configuration.new
      settings.carry_request_headers = %w[traceparent x-cloud-trace-context]
      middleware = Julewire::Rails::RequestMiddleware.new(emitting_app, settings)

      call_and_close(
        middleware,
        ::Rack::MockRequest.env_for(
          "/orders",
          "HTTP_TRACEPARENT" => "00-06796866738c859f2f19b7cfb3214824-000000000000004a-01",
          "HTTP_X_CLOUD_TRACE_CONTEXT" => "06796866738c859f2f19b7cfb3214824/74;o=1",
          "HTTP_AUTHORIZATION" => "secret"
        )
      )

      expected_headers = {
        "traceparent" => "00-06796866738c859f2f19b7cfb3214824-000000000000004a-01",
        "x-cloud-trace-context" => "06796866738c859f2f19b7cfb3214824/74;o=1"
      }

      point, summary = captured

      assert_equal expected_headers, stringified_carry_headers(point)
      assert_equal expected_headers, stringified_carry_headers(summary)
      refute stringified_carry_headers(point).key?("authorization")
    end

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

    def test_request_summary_false_does_not_own_request_errors
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
      refute Julewire::Rails::RequestErrorOwnership.consume?(error)
    ensure
      Julewire::Rails::RequestErrorOwnership.clear
    end

    def test_request_middleware_rejects_all_header_carry_capture
      settings = Julewire::Rails::Configuration.new
      settings.instance_variable_set(:@carry_request_headers, true)
      middleware = Julewire::Rails::RequestMiddleware.new(->(_env) { [200, {}, []] }, settings)

      error = assert_raises(ArgumentError) do
        middleware.call(::Rack::MockRequest.env_for("/orders"))
      end

      assert_equal "carry_request_headers must be an explicit header list", error.message
    end

    def test_request_middleware_computes_all_log_tag_shapes_and_handles_frozen_responses
      output = configure_output
      app = lambda do |_env|
        [204, { "content-type" => "application/json" }, []].freeze
      end
      middleware = Julewire::Rails::RequestMiddleware.new(app, Julewire::Rails::Configuration.new, [
                                                            lambda(&:path),
                                                            :request_method,
                                                            "static"
                                                          ])

      status, _headers, body = middleware.call(::Rack::MockRequest.env_for("/tagged"))
      body.close

      summary = parse_records(output).fetch(0)

      assert_equal 204, status
      assert_equal "summary", summary.fetch("kind")
      assert_equal "/tagged", summary.dig("attributes", "rails", "filtered_path")
      assert_equal "http://example.org/tagged", summary.dig("attributes", "rails", "filtered_url")
    end

    def test_request_body_iteration_restores_request_context
      output = configure_output
      body = Class.new do
        def each
          Julewire.emit(message: "streamed")
          yield "ok"
        end

        def close; end
      end.new
      app = ->(_env) { [200, { "content-type" => "text/plain" }, body] }
      middleware = Julewire::Rails::RequestMiddleware.new(app)

      status, _headers, response_body = middleware.call(
        ::Rack::MockRequest.env_for("/stream", "HTTP_X_REQUEST_ID" => "req-stream")
      )
      chunks = response_body.each.to_a
      response_body.close

      point, summary = parse_records(output)

      assert_equal 200, status
      assert_equal ["ok"], chunks
      assert_equal "streamed", point.fetch("message")
      assert_equal "req-stream", point.dig("context", "request_id")
      assert_equal "closed", completion(summary)
    end

    def test_request_middleware_balances_cleanup_on_non_local_throw
      output = configure_output
      app = ->(_env) { throw :julewire_test_throw }
      middleware = Julewire::Rails::RequestMiddleware.new(app)

      catch(:julewire_test_throw) do
        middleware.call(::Rack::MockRequest.env_for("/throw", "HTTP_X_REQUEST_ID" => "req-throw"))
      end

      summary = parse_records(output).fetch(0)

      assert_equal "req-throw", summary.dig("context", "request_id")
      assert_equal "closed", completion(summary)
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
      settings.request_summary_timeout = 0.01
      middleware = Julewire::Rails::RequestMiddleware.new(->(_env) { [200, {}, []] }, settings)

      _status, _headers, body = middleware.call(::Rack::MockRequest.env_for("/timeout-no-context"))
      warning = wait_for_records(output, count: 1).fetch(0)
      body.close

      assert_equal "request.completion_timeout", warning.fetch("event")
      refute warning.key?("context")
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

    def test_request_middleware_owns_rendered_reportable_errors_before_body_close
      output = configure_output
      error = RuntimeError.new("rendered")
      app = lambda do |env|
        env["action_dispatch.exception"] = error
        env["action_dispatch.report_exception"] = true
        [503, { "content-type" => "text/plain" }, ["failed"]]
      end
      middleware = Julewire::Rails::RequestMiddleware.new(app)
      subscriber = Julewire::Rails::Subscribers::Error.new

      status, _headers, body = middleware.call(rails_exception_env_for("/rendered-error"))
      report_dispatch_error(subscriber, error, path: "/rendered-error")
      body.close

      records = parse_records(output)
      summary = records.find { it["kind"] == "summary" }

      assert_equal 503, status
      refute records.any? { it["event"] == "rails.error" }, records.inspect
      assert_request_error_summary(summary, status: 503)
    end

    def test_request_middleware_owns_escaped_errors_for_dedup
      output = configure_output
      error = RuntimeError.new("escaped")
      app = ->(_env) { raise error }
      middleware = Julewire::Rails::RequestMiddleware.new(app)
      subscriber = Julewire::Rails::Subscribers::Error.new

      assert_raises(RuntimeError) { middleware.call(rails_exception_env_for("/escaped-error")) }
      report_dispatch_error(subscriber, error, path: "/escaped-error")

      records = parse_records(output)
      summary = records.find { it["kind"] == "summary" }

      refute records.any? { it["event"] == "rails.error" }, records.inspect
      assert_request_error_summary(summary, status: 500)
    end

    def test_request_error_ownership_is_cleared_at_next_request_entry
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

      records = parse_records(output)
      rails_error = records.find { it["event"] == "rails.error" }

      refute_nil rails_error, records.inspect
      assert_equal "first", rails_error.dig("error", "message")
    end

    def test_request_summary_timeout_scheduler_ignores_nil_timeout
      called = false

      assert_nil Julewire::Rails::RequestSummaryTimeoutScheduler.schedule(nil) { called = true }
      refute called
    end

    def test_request_summary_timeout_scheduler_runs_non_positive_timeout_inline
      ran_inline = false

      assert_nil Julewire::Rails::RequestSummaryTimeoutScheduler.schedule(0) { ran_inline = true }
      assert ran_inline
    end

    def test_request_summary_timeout_scheduler_cancel_suppresses_callback
      queue = Queue.new

      token = Julewire::Rails::RequestSummaryTimeoutScheduler.schedule(0.01) { queue << :cancelled }

      Julewire::Rails::RequestSummaryTimeoutScheduler.cancel(token)
      Julewire::Rails::RequestSummaryTimeoutScheduler.schedule(0.02) { queue << :sentinel }

      assert_equal :sentinel, Timeout.timeout(1) { queue.pop }
      assert_empty Julewire::Core::Testing.nonblocking_queue_values(queue)
    end

    def test_request_summary_timeout_scheduler_after_fork_resets_pending_callbacks
      queue = Queue.new

      Julewire::Rails::RequestSummaryTimeoutScheduler.schedule(0.01) { queue << :old }
      Julewire::Rails::RequestSummaryTimeoutScheduler.after_fork!
      Julewire::Rails::RequestSummaryTimeoutScheduler.schedule(0.001) { queue << :new }

      assert_equal :new, Timeout.timeout(1) { queue.pop }
      assert_empty Julewire::Core::Testing.nonblocking_queue_values(queue)
    end

    def test_context_body_proxy_restores_context_for_iteration_and_delegation
      contexts = 0
      handle = counting_context_handle { contexts += 1 }
      proxy = Julewire::Rails::ContextBodyProxy.new(proxy_body, handle: handle, on_close: -> {})

      assert_equal ["chunk"], proxy.each.to_a
      assert_equal "custom value", proxy.custom("value")
      assert_raises(NoMethodError) { proxy.to_str }

      assert_equal 2, contexts
    end

    def test_context_body_proxy_array_conversion_closes_once
      contexts = 0
      closes = 0
      handle = counting_context_handle { contexts += 1 }
      body = proxy_body
      proxy = Julewire::Rails::ContextBodyProxy.new(body, handle: handle, on_close: -> { closes += 1 })

      assert_equal ["array"], proxy.to_ary
      proxy.close

      assert_equal 2, contexts
      assert_equal 1, body.closed_count
      assert_equal 1, closes
      assert_predicate proxy, :closed?
    end

    def test_request_middleware_records_errors_and_reraises
      output = configure_output
      app = ->(_env) { raise "app failed" }
      middleware = Julewire::Rails::RequestMiddleware.new(app)

      assert_raises(RuntimeError) { middleware.call(rails_exception_env_for("/failed")) }

      summary = parse_records(output).fetch(0)

      assert_equal "summary", summary.fetch("kind")
      assert_equal 500, summary_status(summary)
      assert_equal "RuntimeError", summary.dig("attributes", "rails", "error_class")
    end

    def test_request_middleware_uses_rails_exception_log_level_for_escaped_errors
      output = configure_output
      app = ->(_env) { raise "fatal app failed" }
      middleware = Julewire::Rails::RequestMiddleware.new(app)
      env = rails_exception_env_for("/fatal")
      env["action_dispatch.debug_exception_log_level"] = ::Logger::FATAL

      assert_raises(RuntimeError) { middleware.call(env) }

      summary = parse_records(output).fetch(0)

      assert_equal "fatal", summary.fetch("severity")
      assert_equal "RuntimeError", summary.dig("error", "class")
    end

    def test_request_middleware_defaults_escaped_error_severity_when_rails_header_is_missing
      output = configure_output
      app = ->(_env) { raise "missing level" }
      middleware = Julewire::Rails::RequestMiddleware.new(app)
      env = rails_exception_env_for("/missing-level")
      env.delete("action_dispatch.debug_exception_log_level")

      assert_raises(RuntimeError) { middleware.call(env) }

      summary = parse_records(output).fetch(0)

      assert_equal "error", summary.fetch("severity")
      assert_equal "RuntimeError", summary.dig("error", "class")
    end

    def test_request_middleware_leaves_app_rescued_errors_unowned
      output = configure_output
      app = lambda do |_env|
        raise "rescued"
      rescue StandardError
        [200, {}, []]
      end
      middleware = Julewire::Rails::RequestMiddleware.new(app)

      call_and_close(middleware, ::Rack::MockRequest.env_for("/rescued"))

      summary = parse_records(output).find { it["kind"] == "summary" }

      assert_equal 200, summary_status(summary)
      assert_equal "closed", completion(summary)
      refute summary.fetch("attributes").fetch("rails", {}).key?("error_class")
      refute summary.key?("error")
    end

    def test_request_middleware_can_skip_context_and_carry
      output = configure_output
      settings = Julewire::Rails::Configuration.new
      settings.request_context = false
      settings.carry_request_headers = nil
      middleware = Julewire::Rails::RequestMiddleware.new(emitting_app, settings)

      call_and_close(middleware, ::Rack::MockRequest.env_for("/orders", "HTTP_TRACEPARENT" => "trace"))

      point = parse_records(output).fetch(0)

      refute point.key?("context")
      refute point.key?("carry")
    end

    def test_request_middleware_excludes_configured_path_prefixes
      output = configure_output
      settings = Julewire::Rails::Configuration.new
      settings.request_exclude_prefixes = ["/julewire_tail"]
      app = lambda do |_env|
        Julewire::Rails::Logger.new.info("diagnostic")
        [204, {}, []]
      end
      middleware = Julewire::Rails::RequestMiddleware.new(app, settings)

      call_and_close(middleware, ::Rack::MockRequest.env_for("/julewire_tail/tail/events"))

      assert_empty parse_records(output)

      call_and_close(middleware, ::Rack::MockRequest.env_for("/julewire_tailored"))

      point, summary = parse_records(output)

      assert_equal "diagnostic", point.fetch("message")
      assert_equal "request.completed", summary.fetch("event")
      assert_equal "/julewire_tailored", summary.dig("context", "path")
    end

    def test_request_context_tolerates_missing_context_integrations
      output = configure_output
      reporter = Object.new
      reporter.define_singleton_method(:context) { raise "context failed" }
      context = Julewire::Rails::RequestContext.new(
        configuration: Julewire::Rails::Configuration.new,
        request: action_dispatch_request("/failed"),
        active_support_context: nil,
        event_reporter: reporter
      )

      context.call { Julewire.emit(message: "inside") }

      point = parse_records(output).fetch(0)

      assert_equal "inside", point.fetch("message")
      assert_equal "/failed", point.dig("context", "path")
    end

    def test_request_attribute_helpers_contain_reader_failures
      request = ::Rack::Request.new(::Rack::MockRequest.env_for("/edge", "HTTP_X_REQUEST_ID" => "req-1"))
      bad_attribute_request = double_bad_attribute_request

      assert_equal "req-1", Julewire::Rails::RequestAttributes.request_id(request)
      neutral = Julewire::Rails::RequestAttributes.request(bad_attribute_request)

      refute_includes neutral, Julewire::Core::Fields::AttributeKeys::URL_FULL
      refute_includes neutral, Julewire::Core::Fields::AttributeKeys::USER_AGENT_ORIGINAL
    end

    def test_request_context_restores_rails_event_context
      context, calls = rails_event_context_probe({ request_id: "previous" })

      context.call { calls << [:yielded] }

      set_call, yielded_call, clear_call, restore_call = calls

      assert_equal :set, set_call.fetch(0)
      assert_equal "/orders", set_call.fetch(1).fetch(:path)
      assert_equal [:yielded], yielded_call
      assert_equal [:clear], clear_call
      assert_equal [:set, { request_id: "previous" }], restore_call
    end

    def test_request_context_clears_rails_event_context_when_previous_context_is_nil
      context, calls = rails_event_context_probe(nil)

      context.call { calls << [:yielded] }

      set_call, yielded_call, clear_call = calls

      assert_equal :set, set_call.fetch(0)
      assert_equal "/orders", set_call.fetch(1).fetch(:path)
      assert_equal [:yielded], yielded_call
      assert_equal [:clear], clear_call
      assert_equal 3, calls.length
    end

    def rails_event_context_probe(previous)
      calls = []
      reporter = Object.new
      reporter.define_singleton_method(:context) { previous }
      reporter.define_singleton_method(:set_context) { calls << [:set, it] }
      reporter.define_singleton_method(:clear_context) { calls << [:clear] }
      context = Julewire::Rails::RequestContext.new(
        configuration: Julewire::Rails::Configuration.new,
        request: action_dispatch_request("/orders"),
        event_reporter: reporter
      )
      [context, calls]
    end

    def test_request_completion_finish_instrumentation_tolerates_missing_handle
      assert_nil Julewire::Rails::RequestCompletion.finish_instrumentation(nil)
    end

    def exercise_rails_boundary_contract(emit_point:, add_summary:, traceparent:, **)
      settings = Julewire::Rails::Configuration.new
      settings.carry_request_headers = %w[traceparent]
      middleware = Julewire::Rails::RequestMiddleware.new(
        lambda do |_env|
          add_summary.call
          emit_point.call
          [200, { "content-type" => "text/plain" }, ["ok"]]
        end,
        settings
      )

      call_and_close(
        middleware,
        ::Rack::MockRequest.env_for(
          "/contract",
          "HTTP_X_REQUEST_ID" => "request-1",
          "HTTP_TRACEPARENT" => traceparent
        )
      )
    end

    def call_and_close(middleware, env)
      response = middleware.call(env)
      response[2].close if response[2].respond_to?(:close)
      response
    end

    def action_dispatch_request(path)
      ::ActionDispatch::Request.new(::Rack::MockRequest.env_for(path))
    end

    def rails_exception_env_for(path)
      ::Rack::MockRequest.env_for(path).tap do |env|
        env["action_dispatch.debug_exception_log_level"] = ::Logger::ERROR
        env["action_dispatch.backtrace_cleaner"] = ActiveSupport::BacktraceCleaner.new
      end
    end

    def report_dispatch_error(subscriber, error, path:)
      subscriber.report(
        error,
        handled: false,
        severity: :error,
        context: { path: path },
        source: "application.action_dispatch"
      )
    end

    def assert_request_error_summary(summary, status:)
      assert_equal "error", summary.fetch("severity")
      assert_equal "error", completion(summary)
      assert_equal status, summary_status(summary)
      assert_equal "RuntimeError", summary.dig("attributes", "rails", "error_class")
      assert_equal "RuntimeError", summary.dig("error", "class")
    end

    def assert_timeout_warning(warning, request_id:, path:)
      assert_equal "request.completion_timeout", warning.fetch("event")
      assert_equal request_id, warning.dig("context", "request_id")
      assert_equal path, warning.dig("context", "path")
      assert_equal 10, warning.dig("attributes", "rails", "completion_timeout_ms")
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

    def counting_context_handle
      Object.new.tap do |handle|
        handle.define_singleton_method(:with_context) do |&block|
          yield
          block.call
        end
      end
    end

    def proxy_body
      Class.new do
        attr_reader :closed_count

        def initialize = @closed_count = 0

        def each
          yield "chunk"
        end

        def close
          @closed_count += 1
        end

        def custom(value)
          "custom #{value}"
        end

        def to_ary
          ["array"]
        end
      end.new
    end

    def double_bad_attribute_request
      Object.new.tap do |object|
        object.define_singleton_method(:request_method) { "GET" }
        object.define_singleton_method(:path) { "/edge" }
        object.define_singleton_method(:protocol) { raise "bad url" }
        object.define_singleton_method(:remote_ip) { "127.0.0.1" }
        object.define_singleton_method(:get_header) { |_key| raise "header failed" }
      end
    end
  end
end
