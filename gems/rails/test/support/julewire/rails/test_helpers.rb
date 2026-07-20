# frozen_string_literal: true

require "action_dispatch/http/response"
require "rack/mock"

module Julewire
  module Rails
    module TestHelpers
      include Julewire::TestSupport::MethodOverride

      Event = Data.define(:payload)

      def configure_output(captured: nil)
        output = StringIO.new
        Julewire.configure do |config|
          formatter = Julewire::Core::Records::Formatter.new
          if captured
            record_formatter = formatter
            formatter = lambda do |record|
              captured << Julewire::Core::Fields::FieldSet.deep_dup(record)
              record_formatter.call(record)
            end
          end
          config.destinations.use(:default, formatter: formatter, output: output)
        end
        output
      end

      def parse_records(output)
        output.string.lines.map { JSON.parse(it) }
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

      def with_fake_rails_application_filter_parameters(filters, &)
        config = Data.define(:filter_parameters).new(filters)
        app = Data.define(:config).new(config)

        with_overridden_singleton_method(::Rails, :application, proc { app }, &)
      end

      def reset_rails_lifecycle_hooks
        Julewire::Rails::LifecycleHooks.instance_variable_set(:@at_exit_installed, false)
        Julewire::Rails::LifecycleHooks.instance_variable_set(:@fork_tracker_installed, false)
      end

      def reset_request_summary_timeout_scheduler
        Julewire::Rails::RequestSummaryTimeoutScheduler.after_fork!
      end

      def with_temporary_constant(owner, name, value)
        existed = owner.const_defined?(name, false)
        previous = owner.const_get(name, false) if existed
        owner.__send__(:remove_const, name) if existed
        owner.const_set(name, value)
        yield
      ensure
        owner.__send__(:remove_const, name) if owner.const_defined?(name, false)
        owner.const_set(name, previous) if existed
      end

      alias with_constant with_temporary_constant

      def with_shadowed_nested_rails_support(&)
        event_reporter = Module.new do
          def self.default = raise "nested RailsSupport must not be used"
          def self.subscribable?(_reporter) = raise "nested RailsSupport must not be used"
          def self.subscribe(*) = raise "nested RailsSupport must not be used"
        end

        with_shadowed_rails_namespace(:RailsSupport, :EventReporter, event_reporter, &)
      end

      def with_shadowed_active_support_execution_state(&)
        execution_state = Module.new do
          def self.[](_key)
            raise "nested ActiveSupport execution state read"
          end

          def self.[]=(_key, _value)
            raise "nested ActiveSupport execution state write"
          end

          def self.delete(_key)
            raise "nested ActiveSupport execution state delete"
          end
        end

        with_shadowed_rails_namespace(:ActiveSupport, :IsolatedExecutionState, execution_state, &)
      end

      def emitting_app
        lambda do |_env|
          Julewire.emit(message: "inside")
          [200, { "content-type" => "text/plain" }, ["ok"]]
        end
      end

      def stringified_carry_headers(record)
        Julewire::Core::Serialization::Serializer.call(record.dig(:carry, :http, :request_headers))
      end

      def emit_request_started(subscriber)
        subscriber.emit(
          name: "action_controller.request_started",
          payload: { controller: "HomeController", action: "index", format: "HTML", params: { id: "1" } },
          tags: {},
          context: {}
        )
      end

      def emit_request_completed(subscriber)
        subscriber.emit(
          name: "action_controller.request_completed",
          payload: {
            controller: "HomeController",
            action: "index",
            format: "HTML",
            status: 200,
            db_runtime: 1.2,
            duration_ms: 4.56
          },
          tags: {},
          context: {}
        )
      end

      def capture_controller_response_summary(response, limit: 65_536, **options)
        response_capture = {
          body: true,
          body_bytes: limit
        }.merge(options.delete(:response_capture) || {})
        capture_controller_summary(
          {
            response: response,
            response_capture: response_capture
          }.merge(options)
        )
      end

      def capture_controller_summary(payload_options)
        output = configure_output
        settings = Julewire::Rails::Configuration.new
        apply_capture_options(settings, payload_options)
        subscriber = Julewire::Rails::Subscribers::ControllerResponse.new(settings)
        payload = payload_options.slice(:request, :response)

        Julewire.with_execution(type: :request, id: "req-1", summary_event: "request.completed") do
          subscriber.process_action(Event.new(payload: payload))
        end

        parse_records(output).fetch(0)
      end

      def apply_capture_options(settings, payload_options)
        apply_named_capture_options(settings.request_capture, payload_options[:request_capture])
        apply_named_capture_options(settings.response_capture, payload_options[:response_capture])
      end

      def apply_named_capture_options(capture, options)
        return unless options

        options.each do |key, value|
          capture.public_send("#{key}=", value)
        end
      end

      def with_shadowed_rails_namespace(name, nested_name, nested_value, &)
        namespace = Module.new
        namespace.const_set(nested_name, nested_value)

        with_temporary_constant(Julewire::Rails, name, namespace, &)
      end

      class FakeMiddlewareStack
        attr_reader :calls

        def initialize
          @calls = []
        end

        def insert_after(*arguments)
          calls << [:insert_after, *arguments]
        end

        def insert_before(*arguments)
          calls << [:insert_before, *arguments]
        end

        def swap(*arguments)
          calls << [:swap, *arguments]
        end

        def use(*arguments)
          calls << [:use, *arguments]
        end
      end

      class FakeAtExit
        attr_reader :hooks

        def initialize
          @hooks = []
        end

        def at_exit(&block)
          hooks << block
        end
      end

      class FakeForkTracker
        attr_reader :hooks

        def initialize
          @hooks = []
        end

        def after_fork(&block)
          hooks << block
          block
        end
      end
    end
  end
end
