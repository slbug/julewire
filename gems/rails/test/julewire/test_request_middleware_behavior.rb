# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestRequestMiddleware < Minitest::Test
    cover Julewire::Rails::RequestMiddleware
    cover Julewire::Rails::RequestLifecycle
    cover "Julewire::Rails::RequestMiddleware#call"
    cover "Julewire::Rails::RequestMiddleware#own_request_error"
    cover "Julewire::Rails::RequestLifecycle#start_execution!"

    def test_request_middleware_wraps_request_in_execution_summary
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
      assert_false summary.fetch("payload", {}).key?("request_id")
      assert_equal "req-1", summary.dig("context", "request_id")
      assert_equal "req-1", summary.dig("execution", "id")
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
      assert_equal "rails", summary.fetch("source")
      assert_equal "summary", summary.fetch("kind")
    end

    def test_request_middleware_uses_configured_summary_event
      output = configure_output
      settings = Julewire::Rails::Configuration.new
      settings.summary_event = "http.request.finished"
      middleware = Julewire::Rails::RequestMiddleware.new(->(_env) { [200, {}, []] }, settings)

      _status, _headers, body = middleware.call(::Rack::MockRequest.env_for("/custom-summary-event"))
      body.close

      summary = parse_records(output).fetch(0)

      assert_equal "http.request.finished", summary.fetch("event")
      assert_equal "rails", summary.fetch("source")
      assert_equal "summary", summary.fetch("kind")
    end

    def test_request_middleware_propagates_context_and_emits_point_and_summary
      output = StringIO.new
      formatter = :to_h.to_proc
      traceparent = "00-06796866738c859f2f19b7cfb3214824-000000000000004a-01"
      settings = Julewire::Rails::Configuration.new
      settings.carry_request_headers = %w[traceparent]
      middleware = Julewire::Rails::RequestMiddleware.new(
        lambda do |_env|
          Julewire.summary.add(total: 2)
          Julewire.emit(event: "contract.point", source: "contract", message: "point", payload: { value: 1 })
          [200, { "content-type" => "text/plain" }, ["ok"]]
        end,
        settings
      )

      Julewire.configure { configure_destination(it, formatter: formatter, output: output) }
      call_and_close(
        middleware,
        ::Rack::MockRequest.env_for(
          "/contract",
          "HTTP_X_REQUEST_ID" => "request-1",
          "HTTP_TRACEPARENT" => traceparent
        )
      )
      records = output.string.lines.map { JSON.parse(it) }
      point = records.find { it.fetch("event") == "contract.point" }
      summary = records.find { it.fetch("event") == "request.completed" }

      assert_equal "point", point.fetch("message")
      assert_equal "request-1", point.dig("context", "request_id")
      assert_equal traceparent, point.dig("carry", "http", "request_headers", "traceparent")
      assert_equal 2, summary.dig("payload", "total")
      assert_equal 200, summary_status(summary)
      assert_equal "GET", summary.dig("neutral", "http.request.method")
      assert_equal 200, summary.dig("neutral", "http.response.status_code")
      assert_equal :ok, Julewire.health.fetch(:status)
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
      assert_false stringified_carry_headers(point).key?("authorization")
    end

    def test_request_middleware_computes_all_log_tag_shapes_and_handles_frozen_responses
      output = configure_output
      logger, pushed, popped = tagging_probe_logger
      app = lambda do |_env|
        [204, { "content-type" => "application/json" }, []].freeze
      end
      middleware = Julewire::Rails::RequestMiddleware.new(app, Julewire::Rails::Configuration.new, [
                                                            lambda(&:path),
                                                            :request_method,
                                                            "static"
                                                          ])

      with_overridden_singleton_method(::Rails, :logger, proc { logger }) do
        status, _headers, body = middleware.call(::Rack::MockRequest.env_for("/tagged"))
        body.close

        summary = parse_records(output).fetch(0)

        assert_equal 204, status
        assert_equal "summary", summary.fetch("kind")
        assert_equal "/tagged", summary.dig("attributes", "rails", "filtered_path")
        assert_equal "http://example.org/tagged", summary.dig("attributes", "rails", "filtered_url")
      end

      assert_equal [["/tagged", "GET", "static"]], pushed
      assert_equal [3], popped
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

    def test_request_middleware_pops_tags_when_instrumentation_start_fails
      logger, popped = rollback_probe_logger
      instrumenter = failing_instrumenter("instrumentation boom")
      middleware = Julewire::Rails::RequestMiddleware.new(
        emitting_app,
        Julewire::Rails::Configuration.new,
        ["tagged"]
      )

      with_overridden_singleton_method(::Rails, :logger, proc { logger }) do
        with_overridden_singleton_method(::ActiveSupport::Notifications, :instrumenter, proc {
          instrumenter
        }) do
          error = assert_raises(RuntimeError) do
            middleware.call(::Rack::MockRequest.env_for("/instrumentation-fails"))
          end

          assert_equal "instrumentation boom", error.message
        end
      end

      assert_equal [1], popped
    end

    def test_request_middleware_ignores_tag_pop_failures
      output = configure_output
      logger = Object.new
      logger.define_singleton_method(:push_tags) { |*tags| tags }
      logger.define_singleton_method(:pop_tags) { |_count| raise "pop failed" }
      middleware = tagged_request_middleware

      with_overridden_singleton_method(::Rails, :logger, proc { logger }) do
        call_and_close_request(middleware, "/pop-fails")
      end

      summary = parse_records(output).fetch(0)

      assert_equal "closed", completion(summary)
    end

    def test_request_middleware_finishes_instrumentation_when_context_fails_before_execution
      output = configure_output
      calls = []
      instrumenter = instrumenter_probe(calls)
      failing_context = Class.new do
        def initialize(*) = nil
        def call = raise "context failed"
      end
      middleware = Julewire::Rails::RequestMiddleware.new(->(_env) { [200, {}, []] })

      with_temporary_constant(Julewire::Rails, :RequestContext, failing_context) do
        with_overridden_singleton_method(::ActiveSupport::Notifications, :instrumenter, proc {
          instrumenter
        }) do
          error = assert_raises(RuntimeError) do
            middleware.call(::Rack::MockRequest.env_for("/context-fails-before-execution"))
          end

          assert_equal "context failed", error.message
        end
      end

      assert_equal [[:build, "request.action_dispatch", "/context-fails-before-execution"], :start, :finish],
                   calls
      assert_empty parse_records(output)
    end

    def test_request_lifecycle_finishes_unattached_request_inside_execution_context
      inside_context = false
      instrumentation_finishes = []
      execution_finishes = []
      instrumenter = instrumenter_probe_with_finish { instrumentation_finishes << inside_context }
      execution_handle = Object.new
      execution_handle.define_singleton_method(:with_context) do |&block|
        inside_context = true
        block.call
      ensure
        inside_context = false
      end
      execution_handle.define_singleton_method(:finish) do |reason:|
        execution_finishes << [reason, inside_context]
      end
      lifecycle = Julewire::Rails::RequestLifecycle.new(
        configuration: Julewire::Rails::Configuration.new,
        env: {},
        request: action_dispatch_request("/unattached-context"),
        taggers: []
      )

      with_overridden_singleton_method(::ActiveSupport::Notifications, :instrumenter, proc { instrumenter }) do
        with_overridden_singleton_method(Julewire, :start_execution, proc { |**_fields| execution_handle }) do
          lifecycle.start
          lifecycle.start_execution!(neutral: {})
          lifecycle.finish_unattached
        end
      end

      assert_equal [true], instrumentation_finishes
      assert_equal [[:closed, true]], execution_finishes
    end

    def test_request_middleware_finishes_active_support_instrumentation_on_body_close
      output = configure_output
      calls = []
      instrumenter = instrumenter_probe(calls)
      middleware = Julewire::Rails::RequestMiddleware.new(->(_env) { [200, {}, []] })

      with_overridden_singleton_method(::ActiveSupport::Notifications, :instrumenter, proc { instrumenter }) do
        _status, _headers, body = middleware.call(::Rack::MockRequest.env_for("/instrumented"))

        assert_equal [[:build, "request.action_dispatch", "/instrumented"], :start], calls

        body.close
      end

      summary = parse_records(output).fetch(0)

      assert_equal [[:build, "request.action_dispatch", "/instrumented"], :start, :finish], calls
      assert_equal "closed", completion(summary)
    end

    def test_request_middleware_instrumentation_uses_top_level_active_support
      calls = []
      instrumenter = instrumenter_probe(calls)
      shadow = Module.new do
        def self.const_missing(_name)
          raise "shadow ActiveSupport namespace used"
        end
      end
      middleware = Julewire::Rails::RequestMiddleware.new(->(_env) { [204, {}, []] })

      with_temporary_constant(Julewire::Rails, :ActiveSupport, shadow) do
        with_overridden_singleton_method(::ActiveSupport::Notifications, :instrumenter, proc {
          instrumenter
        }) do
          call_and_close_request(middleware, "/top-level-instrumented")
        end
      end

      assert_equal [[:build, "request.action_dispatch", "/top-level-instrumented"], :start, :finish], calls
    end

    def test_request_middleware_runs_when_logger_does_not_support_tags
      output = configure_output
      logger = Object.new
      middleware = tagged_request_middleware

      with_overridden_singleton_method(::Rails, :logger, proc { logger }) do
        call_and_close_request(middleware, "/untagged")
      end

      summary = parse_records(output).fetch(0)

      assert_equal "request.completed", summary.fetch("event")
      assert_equal "closed", completion(summary)
    end

    def test_request_middleware_does_not_pop_tags_when_push_tags_is_missing
      output = configure_output
      popped = []
      logger = Object.new
      logger.define_singleton_method(:pop_tags) { |count| popped << count }
      middleware = tagged_request_middleware

      with_overridden_singleton_method(::Rails, :logger, proc { logger }) do
        call_and_close_request(middleware, "/no-push-tags")
      end

      assert_empty popped
      assert_equal "closed", completion(parse_records(output).fetch(0))
    end

    def test_request_middleware_does_not_pop_tags_when_no_tags_are_pushed
      output = configure_output
      logger, pushed, popped = tagging_probe_logger
      middleware = Julewire::Rails::RequestMiddleware.new(->(_env) { [200, {}, []] })

      with_overridden_singleton_method(::Rails, :logger, proc { logger }) do
        call_and_close_request(middleware, "/empty-tags")
      end

      assert_equal [[]], pushed
      assert_empty popped
      assert_equal "closed", completion(parse_records(output).fetch(0))
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
      assert_false records.any? { it["event"] == "rails.error" }, records.inspect
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

      assert_false records.any? { it["event"] == "rails.error" }, records.inspect
      assert_request_error_summary(summary, status: 500)
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

    def test_request_middleware_records_raised_rescue_response_wrapper
      output = configure_output
      exception_class = define_rescued_exception("JulewireRaisedResponseError", "diagnostics")
      app = ->(_env) { raise exception_class, "raised response" }
      middleware = Julewire::Rails::RequestMiddleware.new(app)

      assert_raises(exception_class) { middleware.call(rails_exception_env_for("/raised-response")) }

      summary = parse_records(output).fetch(0)

      assert_equal "error", summary.fetch("severity")
      assert_equal 500, summary_status(summary)
      assert_true summary.dig("attributes", "rails", "rescue_response")
      assert_equal "diagnostics", summary.dig("attributes", "rails", "rescue_template")
    ensure
      remove_rescued_exception("JulewireRaisedResponseError")
    end

    def test_request_middleware_finishes_summary_when_body_finalizer_install_fails
      output = configure_output
      failing_completion = Class.new do
        def initialize(*) = nil
        def attach(_response) = raise "attach failed"
        def self.finish_instrumentation(*) = nil
      end
      middleware = Julewire::Rails::RequestMiddleware.new(->(_env) { [200, {}, []] })

      with_temporary_constant(Julewire::Rails, :RequestCompletion, failing_completion) do
        assert_raises(RuntimeError) { middleware.call(::Rack::MockRequest.env_for("/attach-failed")) }
      end

      summary = parse_records(output).fetch(0)

      assert_equal "error", summary.fetch("severity")
      assert_equal "error", completion(summary)
      assert_equal "RuntimeError", summary.dig("error", "class")
    end

    def test_request_middleware_reraises_request_construction_failures
      middleware = Julewire::Rails::RequestMiddleware.new(->(_env) { [200, {}, []] })
      replacement = proc { |_env| raise "request failed" }

      with_overridden_singleton_method(::ActionDispatch::Request, :new, replacement) do
        error = assert_raises(RuntimeError) { middleware.call(::Rack::MockRequest.env_for("/request-failed")) }

        assert_equal "request failed", error.message
      end
    end

    def test_request_middleware_records_rendered_exception_env_status_and_severity
      output = configure_output
      error = RuntimeError.new("rendered env")
      dispatch_error = RuntimeError.new("dispatch env")
      app = lambda do |env|
        env[Julewire::Rails::RequestMiddleware::RENDERED_EXCEPTION_ENV_KEY] = {
          error: error,
          severity: :fatal,
          rescue_response: true,
          rescue_template: "diagnostics/error"
        }
        env["action_dispatch.exception"] = dispatch_error
        [418, {}, []]
      end
      middleware = Julewire::Rails::RequestMiddleware.new(app)
      env = rails_exception_env_for("/rendered-env")

      _status, _headers, body = middleware.call(env)

      request_error = env.fetch(Julewire::Rails::RequestMiddleware::REQUEST_ERROR_ENV_KEY)

      assert_same error, request_error.fetch(:error)
      assert_equal :fatal, request_error.fetch(:severity)

      body.close
      summary = parse_records(output).fetch(0)

      assert_equal "fatal", summary.fetch("severity")
      assert_equal 418, summary_status(summary)
      assert_equal "diagnostics/error", summary.dig("attributes", "rails", "rescue_template")
      assert_true summary.dig("attributes", "rails", "rescue_response")
      assert_equal "RuntimeError", summary.dig("error", "class")
      assert_equal "rendered env", summary.dig("error", "message")
    end

    def test_request_middleware_uses_rails_exception_log_level_for_escaped_errors
      output = configure_output
      app = ->(_env) { raise "fatal app failed" }
      middleware = Julewire::Rails::RequestMiddleware.new(app)
      env = rails_exception_env_for("/fatal")
      env["action_dispatch.debug_exception_log_level"] = ::Logger::FATAL

      assert_raises(RuntimeError) { middleware.call(env) }

      assert_equal :fatal, env.dig(Julewire::Rails::RequestMiddleware::REQUEST_ERROR_ENV_KEY, :severity)

      summary = parse_records(output).fetch(0)

      assert_equal "fatal", summary.fetch("severity")
      assert_equal "RuntimeError", summary.dig("error", "class")
    end

    def test_request_middleware_records_post_response_exception_severity_and_wrapper
      output = configure_output
      exception_class = define_rescued_exception("JulewirePostResponseError", "diagnostics")
      error = exception_class.new("post response")
      app = lambda do |env|
        env["action_dispatch.exception"] = error
        [409, {}, []]
      end
      middleware = Julewire::Rails::RequestMiddleware.new(app)
      env = rails_exception_env_for("/post-response")
      env["action_dispatch.debug_exception_log_level"] = ::Logger::FATAL

      call_and_close(middleware, env)

      request_error = env.fetch(Julewire::Rails::RequestMiddleware::REQUEST_ERROR_ENV_KEY)
      summary = parse_records(output).fetch(0)

      assert_same error, request_error.fetch(:error)
      assert_equal :fatal, request_error.fetch(:severity)
      assert_equal "fatal", summary.fetch("severity")
      assert_equal 409, summary_status(summary)
      assert_true summary.dig("attributes", "rails", "rescue_response")
      assert_equal "diagnostics", summary.dig("attributes", "rails", "rescue_template")
    ensure
      remove_rescued_exception("JulewirePostResponseError")
    end

    def test_request_middleware_passes_backtrace_cleaner_to_top_level_exception_wrapper
      output = configure_output
      error = RuntimeError.new("wrapped")
      cleaner = ActiveSupport::BacktraceCleaner.new
      calls = []
      original_new = ::ActionDispatch::ExceptionWrapper.method(:new)
      replacement = proc do |actual_cleaner, actual_error|
        calls << [actual_cleaner, actual_error]
        original_new.call(actual_cleaner, actual_error)
      end
      shadow_action_dispatch = Module.new do
        const_set(:ExceptionWrapper, Class.new do
          def self.new(*) = raise "nested ActionDispatch must not be used"
        end)
      end
      app = ->(_env) { raise error }
      middleware = Julewire::Rails::RequestMiddleware.new(app)
      env = rails_exception_env_for("/wrapped")
      env["action_dispatch.backtrace_cleaner"] = cleaner

      with_temporary_constant(Julewire::Rails::RequestMiddleware, :ActionDispatch, shadow_action_dispatch) do
        with_overridden_singleton_method(::ActionDispatch::ExceptionWrapper, :new, replacement) do
          assert_raises(RuntimeError) { middleware.call(env) }
        end
      end

      wrapper_cleaner, wrapper_error = calls.fetch(0)

      assert_same cleaner, wrapper_cleaner
      assert_same error, wrapper_error
      assert_equal "RuntimeError", parse_records(output).fetch(0).dig("error", "class")
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
      assert_false summary.fetch("attributes").fetch("rails", {}).key?("error_class")
      assert_false summary.key?("error")
    end

    def test_request_middleware_can_skip_context_and_carry
      output = configure_output
      settings = Julewire::Rails::Configuration.new
      settings.request_context = false
      settings.carry_request_headers = nil
      middleware = Julewire::Rails::RequestMiddleware.new(emitting_app, settings)

      call_and_close(middleware, ::Rack::MockRequest.env_for("/orders", "HTTP_TRACEPARENT" => "trace"))

      point = parse_records(output).fetch(0)

      assert_false point.key?("context")
      assert_false point.key?("carry")
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

      call_and_close(middleware, ::Rack::MockRequest.env_for("/julewire_tail"))
      call_and_close(middleware, ::Rack::MockRequest.env_for("/julewire_tail/tail/events"))

      assert_empty parse_records(output)

      call_and_close(middleware, ::Rack::MockRequest.env_for("/julewire_tailored"))

      point, summary = parse_records(output)

      assert_equal "diagnostic", point.fetch("message")
      assert_equal "request.completed", summary.fetch("event")
      assert_equal "/julewire_tailored", summary.dig("context", "path")
    end

    def test_request_middleware_excludes_root_prefix_and_passes_env_to_app
      output = configure_output
      settings = Julewire::Rails::Configuration.new
      settings.request_exclude_prefixes = ["/"]
      app = lambda do |env|
        assert_equal "/anything", env.fetch("PATH_INFO")
        Julewire::Rails::Logger.new.info("diagnostic")
        [204, {}, []]
      end
      middleware = Julewire::Rails::RequestMiddleware.new(app, settings)

      status, _headers, _body = call_and_close(middleware, ::Rack::MockRequest.env_for("/anything"))

      assert_equal 204, status
      assert_empty parse_records(output)
    end

    def test_request_middleware_uses_top_level_core_for_summary_fields
      output = StringIO.new
      formatter = :to_h.to_proc
      shadow_core = Module.new do
        const_set(:Integration, Module.new do
          const_set(:Facade, Module.new do
            def self.add_summary_attributes(*) = raise "nested Core must not be used"
            def self.add_summary_neutral(*) = raise "nested Core must not be used"
          end)
        end)
      end

      Julewire.configure do |config|
        configure_destination(config, formatter: formatter, output: output)
      end

      with_temporary_constant(Julewire::Rails::RequestMiddleware, :Core, shadow_core) do
        middleware = Julewire::Rails::RequestMiddleware.new(->(_env) { [200, {}, []] })
        call_and_close(middleware, ::Rack::MockRequest.env_for("/core-shadow"))
      end

      summary = parse_records(output).fetch(0)

      assert_equal "request.completed", summary.fetch("event")
      assert_equal 200, summary.dig("neutral", "http.response.status_code")
    end

    def test_request_middleware_requires_summary_attribute_fields
      assert_response_summary_requires_fields("/missing-summary-attributes", replacement: { neutral: {} })
    end

    def test_request_middleware_requires_summary_neutral_fields
      assert_response_summary_requires_fields("/missing-summary-neutral", replacement: { attributes: {} })
    end

    private

    def assert_response_summary_requires_fields(path, replacement:)
      middleware = Julewire::Rails::RequestMiddleware.new(->(_env) { [200, {}, []] })
      summary = proc { |_request, _status, _headers| replacement }

      with_overridden_singleton_method(Julewire::Rails::RequestAttributes, :response_summary, summary) do
        assert_raises(KeyError) { middleware.call(::Rack::MockRequest.env_for(path)) }
      end
    end

    def assert_request_error_summary(summary, status:)
      assert_equal "error", summary.fetch("severity")
      assert_equal "error", completion(summary)
      assert_equal status, summary_status(summary)
      assert_equal "RuntimeError", summary.dig("attributes", "rails", "error_class")
      assert_equal "RuntimeError", summary.dig("error", "class")
    end

    def completion(record)
      record.dig("attributes", "julewire.completion")
    end

    def summary_status(record)
      record.dig("attributes", "rails", "status") || record.dig("attributes", "http.response.status_code")
    end

    def rollback_probe_logger
      popped = []
      logger = Object.new
      logger.define_singleton_method(:push_tags) { |*tags| tags }
      logger.define_singleton_method(:pop_tags) { |count| popped << count }
      [logger, popped]
    end

    def tagging_probe_logger
      pushed = []
      popped = []
      logger = Object.new
      logger.define_singleton_method(:push_tags) do |*tags|
        pushed << tags
        tags
      end
      logger.define_singleton_method(:pop_tags) { |count| popped << count }
      [logger, pushed, popped]
    end

    def failing_instrumenter(message)
      handle = Object.new
      handle.define_singleton_method(:start) { raise message }
      Object.new.tap do |instrumenter|
        instrumenter.define_singleton_method(:build_handle) { |_name, **_payload| handle }
      end
    end

    def instrumenter_probe(calls)
      handle = Object.new
      handle.define_singleton_method(:start) { calls << :start }
      handle.define_singleton_method(:finish) { calls << :finish }
      Object.new.tap do |instrumenter|
        instrumenter.define_singleton_method(:build_handle) do |name, request:|
          calls << [:build, name, request.path]
          handle
        end
      end
    end

    def instrumenter_probe_with_finish(&finish)
      handle = Object.new
      handle.define_singleton_method(:start) { nil }
      handle.define_singleton_method(:finish, finish)
      Object.new.tap do |instrumenter|
        instrumenter.define_singleton_method(:build_handle) { |_name, **| handle }
      end
    end

    def call_and_close_request(middleware, path)
      _status, _headers, body = middleware.call(::Rack::MockRequest.env_for(path))
      body.close
    end

    def tagged_request_middleware
      Julewire::Rails::RequestMiddleware.new(
        ->(_env) { [200, {}, []] },
        Julewire::Rails::Configuration.new,
        ["tagged"]
      )
    end
  end
end
