# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestRequestContext < Minitest::Test
    cover Julewire::Rails::RequestContext
    cover "Julewire::Rails::RequestAttributes.normalize_user_fields"

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

    def test_request_context_uses_default_active_support_execution_context
      calls = []
      replacement = proc do |**fields, &block|
        calls << fields
        block.call
      end
      shadow_core = Module.new { const_set(:UNSET, Object.new) }
      shadow_active_support = Module.new do
        const_set(:ExecutionContext, Module.new do
          def self.set(**) = raise "nested ActiveSupport must not be used"
        end)
      end

      with_overridden_singleton_method(::ActiveSupport::ExecutionContext, :set, replacement) do
        with_temporary_constant(Julewire::Rails::RequestContext, :Core, shadow_core) do
          with_temporary_constant(Julewire::Rails::RequestContext, :ActiveSupport, shadow_active_support) do
            context = Julewire::Rails::RequestContext.new(
              configuration: Julewire::Rails::Configuration.new,
              request: action_dispatch_request("/active-support-default"),
              event_reporter: nil
            )
            context.call { calls << :yielded }
          end
        end
      end

      assert_equal "/active-support-default", calls.fetch(0).fetch(:path)
      assert_equal :yielded, calls.fetch(1)
    end

    def test_request_context_uses_explicit_active_support_context
      calls = []
      explicit_context = Data.define(:calls) do
        def set(**fields)
          calls << fields
          yield
        end
      end.new(calls)
      replacement = proc { raise "default ActiveSupport must not be used" }
      context = Julewire::Rails::RequestContext.new(
        configuration: Julewire::Rails::Configuration.new,
        request: action_dispatch_request("/active-support-explicit"),
        active_support_context: explicit_context,
        event_reporter: nil
      )

      with_overridden_singleton_method(::ActiveSupport::ExecutionContext, :set, replacement) do
        context.call { calls << :yielded }
      end

      assert_equal "/active-support-explicit", calls.fetch(0).fetch(:path)
      assert_equal :yielded, calls.fetch(1)
    end

    def test_request_context_skips_active_support_context_without_set
      calls = []
      context = Julewire::Rails::RequestContext.new(
        configuration: Julewire::Rails::Configuration.new,
        request: action_dispatch_request("/active-support-no-set"),
        active_support_context: Object.new,
        event_reporter: nil
      )

      context.call { calls << :yielded }

      assert_equal [:yielded], calls
    end

    def test_request_context_uses_default_rails_event_reporter
      reporter = rails_event_reporter_probe(nil)
      shadow_core = Module.new { const_set(:UNSET, Object.new) }
      shadow_rails_support = Module.new do
        const_set(:EventReporter, Module.new do
          def self.default = raise "nested RailsSupport must not be used"
        end)
      end

      with_overridden_singleton_method(Julewire::RailsSupport::EventReporter, :default, proc { reporter }) do
        with_temporary_constant(Julewire::Rails::RequestContext, :Core, shadow_core) do
          with_temporary_constant(Julewire::Rails::RequestContext, :RailsSupport, shadow_rails_support) do
            context = Julewire::Rails::RequestContext.new(
              configuration: Julewire::Rails::Configuration.new,
              request: action_dispatch_request("/event-default"),
              active_support_context: nil
            )
            context.call { reporter.calls << [:yielded] }
          end
        end
      end

      assert_equal :set, reporter.calls.fetch(0).fetch(0)
      assert_equal "/event-default", reporter.calls.fetch(0).fetch(1).fetch(:path)
      assert_equal [:yielded], reporter.calls.fetch(1)
      assert_equal [:clear], reporter.calls.fetch(2)
    end

    def test_request_context_skips_rails_event_reporter_without_context
      calls = []
      reporter = Class.new do
        define_method(:initialize) { |observed_calls| @observed_calls = observed_calls }
        define_method(:set_context) { @observed_calls << [:set, it] }
        define_method(:clear_context) { @observed_calls << [:clear] }

        private

        def method_missing(name, *)
          @observed_calls << [:unsupported, name]
          super
        end

        def respond_to_missing?(*, **) = false
      end.new(calls)
      request_context = rails_request_context("/event-missing-context", event_reporter: reporter)

      request_context.call { calls << [:yielded] }

      assert_equal [[:yielded]], calls
    end

    def test_request_context_skips_rails_event_reporter_without_set_context
      assert_request_context_skips_event_reporter(
        "/event-missing-set",
        context: true,
        clear_context: true
      )
    end

    def test_request_context_skips_rails_event_reporter_without_clear_context
      assert_request_context_skips_event_reporter(
        "/event-missing-clear",
        context: true,
        set_context: true
      )
    end

    def test_request_context_yields_once_when_rails_event_context_read_fails
      calls = []
      reporter = Object.new
      reporter.define_singleton_method(:context) { raise "context failed" }
      reporter.define_singleton_method(:set_context) { calls << [:set, it] }
      reporter.define_singleton_method(:clear_context) { calls << [:clear] }
      context = rails_request_context("/event-read-fails", event_reporter: reporter)

      context.call { calls << [:yielded] }

      assert_equal [[:yielded]], calls
    end

    def test_request_context_does_not_restore_when_rails_event_set_fails
      calls = []
      reporter = Object.new
      reporter.define_singleton_method(:context) { { request_id: "previous" } }
      reporter.define_singleton_method(:set_context) { raise "set failed" }
      reporter.define_singleton_method(:clear_context) { calls << [:clear] }
      context = rails_request_context("/event-set-fails", event_reporter: reporter)

      context.call { calls << [:yielded] }

      assert_equal [[:yielded]], calls
    end

    def test_request_context_contains_rails_event_clear_failures
      calls = []
      reporter = Object.new
      reporter.define_singleton_method(:context) { { request_id: "previous" } }
      reporter.define_singleton_method(:set_context) { calls << [:set, it] }
      reporter.define_singleton_method(:clear_context) do
        calls << [:clear]
        raise "clear failed"
      end
      context = rails_request_context("/event-clear-fails", event_reporter: reporter)

      context.call { calls << [:yielded] }

      assert_equal :set, calls.fetch(0).fetch(0)
      assert_equal [:yielded], calls.fetch(1)
      assert_equal [:clear], calls.fetch(2)
      assert_equal 3, calls.length
    end

    def test_request_context_contains_rails_event_restore_failures
      calls = []
      previous = { request_id: "previous" }
      reporter = Object.new
      reporter.define_singleton_method(:context) { previous }
      reporter.define_singleton_method(:set_context) do |fields|
        calls << [:set, fields]
        raise "restore failed" if fields.equal?(previous)
      end
      reporter.define_singleton_method(:clear_context) { calls << [:clear] }
      context = rails_request_context("/event-restore-fails", event_reporter: reporter)

      context.call { calls << [:yielded] }

      assert_equal :set, calls.fetch(0).fetch(0)
      assert_equal [:yielded], calls.fetch(1)
      assert_equal [:clear], calls.fetch(2)
      assert_equal [:set, previous], calls.fetch(3)
    end

    def test_request_context_skips_carry_capture_when_disabled
      output = configure_output
      settings = Julewire::Rails::Configuration.new
      settings.carry_request_headers = nil
      replacement = proc { raise "headers must not be captured" }
      shadow_rack = Module.new do
        const_set(:Capture, Module.new do
          const_set(:Headers, Module.new do
            def self.request(*) = raise "nested Rack must not be used"
          end)
        end)
      end
      context = Julewire::Rails::RequestContext.new(
        configuration: settings,
        request: action_dispatch_request("/carry-disabled"),
        active_support_context: nil,
        event_reporter: nil
      )

      with_temporary_constant(Julewire::Rails::RequestContext, :Rack, shadow_rack) do
        with_overridden_singleton_method(Julewire::Rack::Capture::Headers, :request, replacement) do
          context.call { Julewire.emit(message: "inside") }
        end
      end

      point = parse_records(output).fetch(0)

      assert_equal "inside", point.fetch("message")
      assert_false point.key?("carry")
    end

    def test_request_context_rejects_all_header_carry_capture
      settings = Julewire::Rails::Configuration.new
      settings.instance_variable_set(:@carry_request_headers, true)
      context = Julewire::Rails::RequestContext.new(
        configuration: settings,
        request: action_dispatch_request("/orders"),
        active_support_context: nil,
        event_reporter: nil
      )

      error = assert_raises(ArgumentError) { context.call { flunk "request context yielded" } }

      assert_equal "carry_request_headers must be an explicit header list", error.message
    end

    def test_request_context_skips_carry_overlay_when_selected_headers_are_empty
      output = configure_output
      settings = Julewire::Rails::Configuration.new
      settings.carry_request_headers = %w[traceparent]
      replacement = proc { raise "carry overlay must not be used" }
      shadow_core = Module.new do
        const_set(:Integration, Module.new do
          const_set(:Facade, Module.new do
            def self.with_context(fields, &) = Julewire::Core::Integration::Facade.with_context(fields, &)
            def self.with_carry(*) = raise "carry overlay must not be used"
          end)
        end)
      end
      context = Julewire::Rails::RequestContext.new(
        configuration: settings,
        request: action_dispatch_request("/carry-empty"),
        active_support_context: nil,
        event_reporter: nil
      )

      with_temporary_constant(Julewire::Rails::RequestContext, :Core, shadow_core) do
        with_overridden_singleton_method(Julewire::Core::Integration::Facade, :with_carry, replacement) do
          context.call { Julewire.emit(message: "inside") }
        end
      end

      point = parse_records(output).fetch(0)

      assert_equal "inside", point.fetch("message")
      assert_false point.key?("carry")
    end

    def test_request_context_skips_core_context_when_disabled
      output = configure_output
      settings = Julewire::Rails::Configuration.new
      settings.request_context = false
      replacement = proc { raise "context overlay must not be used" }
      context = Julewire::Rails::RequestContext.new(
        configuration: settings,
        request: action_dispatch_request("/context-disabled"),
        active_support_context: nil,
        event_reporter: nil
      )

      with_overridden_singleton_method(Julewire::Core::Integration::Facade, :with_context, replacement) do
        context.call { Julewire.emit(message: "inside") }
      end

      point = parse_records(output).fetch(0)

      assert_equal "inside", point.fetch("message")
      assert_false point.key?("context")
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

    def test_request_context_clears_rails_event_context_when_previous_context_is_empty
      context, calls = rails_event_context_probe({})

      context.call { calls << [:yielded] }

      set_call, yielded_call, clear_call = calls

      assert_equal :set, set_call.fetch(0)
      assert_equal "/orders", set_call.fetch(1).fetch(:path)
      assert_equal [:yielded], yielded_call
      assert_equal [:clear], clear_call
      assert_equal 3, calls.length
    end

    def test_request_context_uses_top_level_core_and_rack
      captured = []
      configure_output(captured: captured)
      settings = Julewire::Rails::Configuration.new
      settings.carry_request_headers = %w[traceparent]
      shadow_core = Module.new do
        const_set(:Integration, Module.new do
          const_set(:Facade, Module.new do
            def self.with_context(*) = raise "nested Core must not be used"
            def self.with_carry(*) = raise "nested Core must not be used"
          end)
        end)
      end
      shadow_rack = Module.new do
        const_set(:Capture, Module.new do
          const_set(:Headers, Module.new do
            def self.request(*) = raise "nested Rack must not be used"
          end)
        end)
      end
      context = Julewire::Rails::RequestContext.new(
        configuration: settings,
        request: ::ActionDispatch::Request.new(
          ::Rack::MockRequest.env_for("/shadowed",
                                      "HTTP_TRACEPARENT" => "00-06796866738c859f2f19b7cfb3214824-000000000000004a-01")
        ),
        active_support_context: nil,
        event_reporter: nil
      )

      with_temporary_constant(Julewire::Rails::RequestContext, :Core, shadow_core) do
        with_temporary_constant(Julewire::Rails::RequestContext, :Rack, shadow_rack) do
          context.call { Julewire.emit(message: "inside") }
        end
      end

      point = captured.fetch(0)

      assert_equal "inside", point.fetch(:message)
      assert_equal "/shadowed", point.dig(:context, :path)
      assert_equal(
        { traceparent: "00-06796866738c859f2f19b7cfb3214824-000000000000004a-01" },
        point.dig(:carry, :http, :request_headers)
      )
    end

    private

    def rails_event_context_probe(previous)
      reporter = rails_event_reporter_probe(previous)
      context = Julewire::Rails::RequestContext.new(
        configuration: Julewire::Rails::Configuration.new,
        request: action_dispatch_request("/orders"),
        event_reporter: reporter
      )
      [context, reporter.calls]
    end

    def rails_event_reporter_probe(previous)
      Data.define(:previous, :calls) do
        def context = previous

        define_method(:set_context) { |fields| calls << [:set, fields] }

        def clear_context
          calls << [:clear]
          nil
        end
      end.new(previous, [])
    end

    def assert_request_context_skips_event_reporter(path, context: false, set_context: false, clear_context: false)
      calls = []
      reporter = partial_rails_event_reporter(calls, context:, set_context:, clear_context:)
      request_context = rails_request_context(path, event_reporter: reporter)

      request_context.call { calls << [:yielded] }

      assert_equal [[:yielded]], calls
    end

    def partial_rails_event_reporter(calls, context:, set_context:, clear_context:)
      Object.new.tap do |reporter|
        if context
          reporter.define_singleton_method(:context) do
            calls << [:context]
            {}
          end
        end
        reporter.define_singleton_method(:set_context) { calls << [:set, it] } if set_context
        reporter.define_singleton_method(:clear_context) { calls << [:clear] } if clear_context
      end
    end

    def rails_request_context(path, event_reporter:, configuration: Julewire::Rails::Configuration.new)
      Julewire::Rails::RequestContext.new(
        configuration: configuration,
        request: action_dispatch_request(path),
        event_reporter: event_reporter
      )
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
