# frozen_string_literal: true

require "action_dispatch/http/response"
require "rack/mock"

module Julewire
  module Rails
    module TestHelpers
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

      def with_fake_rails_application_filter_parameters(filters, &)
        config = Data.define(:filter_parameters).new(filters)
        app = Data.define(:config).new(config)

        with_overridden_singleton_method(::Rails, :application, proc { app }, &)
      end

      def with_overridden_singleton_method(receiver, method_name, replacement, &)
        Julewire::Core::Testing.with_overridden_singleton_method(receiver, method_name, replacement, &)
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

      def expected_controller_summary_fields
        {
          kind: "summary",
          event: "request.completed",
          controller: "HomeController",
          action: "index",
          format: "HTML",
          status: 200,
          db_runtime: 1.2,
          action_runtime_ms: 4.56,
          has_duration_ms: false
        }
      end

      def controller_summary_fields(summary)
        attributes = summary.fetch("attributes").fetch("rails")
        {
          kind: summary.fetch("kind"),
          event: summary.fetch("event"),
          controller: attributes.fetch("controller"),
          action: attributes.fetch("action"),
          format: attributes.fetch("format"),
          status: attributes.fetch("status"),
          db_runtime: attributes.fetch("db_runtime"),
          action_runtime_ms: attributes.fetch("action_runtime_ms"),
          has_duration_ms: attributes.key?("duration_ms")
        }
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
