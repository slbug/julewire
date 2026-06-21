# frozen_string_literal: true

require "test_helper"
require_relative "../dummy/config/environment"

module Julewire
  class TestRailsStack < Minitest::Test
    def setup
      super
      ensure_schema!
      Julewire::Rails::Railtie.install_subscribers(::Rails.application.config.julewire_rails)
    end

    def test_real_rails_stack_emits_framework_events_logger_calls_and_summary
      output = configure_output
      response = request.get(
        "/stack/html",
        "HTTP_ACCEPT" => "text/html",
        "HTTP_TRACEPARENT" => "00-06796866738c859f2f19b7cfb3214824-000000000000004a-01"
      )

      assert_equal 200, response.status

      records = parse_records(output)

      assert_event records, "active_record.sql"
      refute_event records, "action_view.render_template"
      assert_logger_message records, "controller explicit logger"

      summary = summary_record(records)

      assert_equal "request.completed", summary.fetch("event")
      assert_equal 200, summary.dig("attributes", "rails", "status")
      assert_equal "StackController", summary.dig("attributes", "rails", "controller")
      assert_equal "html", summary.dig("attributes", "rails", "action")
      assert_equal "GET", summary.dig("context", "http_method")
      assert_equal "/stack/html", summary.dig("context", "path")
      assert_equal "00-06796866738c859f2f19b7cfb3214824-000000000000004a-01",
                   summary.dig("attributes", "rails", "request_headers", "traceparent")
    end

    def test_real_rails_stack_can_opt_into_selected_view_events
      output = configure_output
      settings = ::Rails.application.config.julewire_rails
      previous_names = settings.structured_event_names
      settings.structured_event_names = %w[action_view.render_template]

      request.get("/stack/html", "HTTP_ACCEPT" => "text/html")

      assert_event parse_records(output), "action_view.render_template"
    ensure
      settings.structured_event_names = previous_names if defined?(previous_names)
    end

    def test_framework_log_subscribers_are_silenced_but_logger_calls_remain
      output = configure_output

      request.get("/stack/html", "HTTP_ACCEPT" => "text/html")

      messages = parse_records(output).filter_map { it["message"] }

      assert_includes messages, "controller explicit logger"
      refute messages.any? { it.include?("Processing by ") }, messages.inspect
      refute messages.any? { |message| message.match?(/Completed \d{3}/) }, messages.inspect
    end

    def test_real_rails_stack_captures_json_response_body_by_default
      output = configure_output

      request.get("/stack/json", "HTTP_ACCEPT" => "application/json")

      summary = summary_record(parse_records(output))

      assert_match(/"ok":true/, summary.dig("attributes", "rails", "response_body"))
      refute summary.dig("attributes", "rails", "response_body_truncated")
      assert_equal "application/json; charset=utf-8", summary.dig("attributes", "rails", "response_content_type")
    end

    def test_real_rails_stack_can_capture_json_response_body_as_structured_json
      output = configure_output
      settings = ::Rails.application.config.julewire_rails
      previous = settings.response_capture.body
      settings.response_capture.body = :json

      request.get("/stack/json", "HTTP_ACCEPT" => "application/json")

      summary = summary_record(parse_records(output))
      rails = summary.fetch("attributes").fetch("rails")

      assert rails.dig("response_body_json", "ok")
      refute rails.key?("response_body")
      refute rails.fetch("response_body_truncated")
      assert_equal "application/json; charset=utf-8", rails.fetch("response_content_type")
    ensure
      settings.response_capture.body = previous if defined?(previous)
    end

    def test_real_rails_stack_skips_non_json_response_body_by_default
      output = configure_output

      request.get("/stack/html", "HTTP_ACCEPT" => "text/html")

      summary = summary_record(parse_records(output))

      refute summary.dig("attributes", "rails").to_h.key?("response_body")
      assert_equal "text/html; charset=utf-8", summary.dig("attributes", "rails", "response_content_type")
    end

    def test_real_rails_stack_skips_binary_response_body_even_with_capture_enabled
      output = configure_output
      settings = ::Rails.application.config.julewire_rails
      previous = settings.response_capture.body_content_types
      settings.response_capture.body_content_types = true

      request.get("/stack/binary")

      summary = summary_record(parse_records(output))

      refute summary.dig("attributes", "rails").to_h.key?("response_body")
    ensure
      settings.response_capture.body_content_types = previous if defined?(previous)
    end

    def test_request_context_is_mirrored_to_rails_event_and_error_context
      output = configure_output
      subscriber = EventCapture.new("stack.context_probe")
      ::Rails.event.subscribe(subscriber) { it[:name] == "stack.context_probe" }

      request.get("/stack/event_context")

      event_context = subscriber.events.fetch(0).fetch(:context)
      error_record = parse_records(output).find { it["event"] == "rails.error" }

      assert_equal "/stack/event_context", event_context.fetch(:path)
      assert_equal "GET", event_context.fetch(:http_method)
      assert_equal "/stack/event_context", error_record.dig("context", "path")
      assert_equal "GET", error_record.dig("context", "http_method")
      assert_equal "stack", error_record.dig("context", "section")
    ensure
      ::Rails.event.unsubscribe(subscriber) if defined?(subscriber)
    end

    def test_real_rails_stack_records_rescued_request_errors_on_summary_without_raw_text
      output = configure_output

      response = request.post("/missing")

      assert_equal 404, response.status

      records = parse_records(output)
      summary = summary_record(records)

      assert_rescued_request_error_summary(summary)
      refute records.any? { it["event"] == "action_dispatch.rendered_exception" }, records.inspect
      refute_logger_message_includes(records, "No route matches")
    end

    def test_real_rails_stack_records_unhandled_request_errors_on_summary
      output = configure_output

      response = request.get("/stack/error")

      assert_equal 500, response.status

      records = parse_records(output)
      rails_error = records.find { it["event"] == "rails.error" }
      summary = summary_record(records)

      refute rails_error, "expected no duplicate rails.error in #{records.inspect}"
      assert_stack_error_summary(summary)
      refute_logger_message_includes(records, "stack boom")
    end

    def test_real_rails_stack_leaves_controller_rescued_errors_out_of_summary_errors
      output = configure_output

      response = request.get("/stack/rescued_error")

      assert_equal 200, response.status

      records = parse_records(output)
      summary = summary_record(records)

      assert_equal "info", summary.fetch("severity")
      assert_equal 200, summary.dig("attributes", "rails", "status")
      assert_equal "closed", summary.dig("attributes", "rails", "completion")
      refute summary.fetch("attributes").fetch("rails").key?("error_class")
      refute summary.key?("error")
      refute records.any? { it["event"] == "rails.error" }, records.inspect
      refute records.any? { it["event"] == "action_dispatch.rendered_exception" }, records.inspect
    end

    private

    def assert_stack_error_summary(summary)
      assert_equal "error", summary.fetch("severity")
      assert_equal "error", summary.dig("attributes", "rails", "completion")
      assert_equal 500, summary.dig("attributes", "rails", "status")
      assert_equal "RuntimeError", summary.dig("attributes", "rails", "error_class")
      assert_equal "RuntimeError", summary.dig("error", "class")
      assert_equal "stack boom", summary.dig("error", "message")
      assert_equal "StackController", summary.dig("attributes", "rails", "controller")
    end

    def assert_rescued_request_error_summary(summary)
      assert_equal "error", summary.fetch("severity")
      assert_equal "ActionController::RoutingError", summary.dig("error", "class")
      assert_equal 404, summary.dig("attributes", "rails", "status")
      assert_equal "ActionController::RoutingError", summary.dig("attributes", "rails", "error_class")
      assert summary.dig("attributes", "rails", "rescue_response")
      assert_equal "routing_error", summary.dig("attributes", "rails", "rescue_template")
    end

    class EventCapture
      attr_reader :events

      def initialize(name)
        @name = name
        @events = []
      end

      def emit(event)
        return unless event[:name] == @name

        events << event
      end
    end

    def request
      @request ||= ::Rack::MockRequest.new(::Rails.application)
    end

    def ensure_schema!
      return if self.class.schema_loaded?

      previous_verbose = ActiveRecord::Migration.verbose
      ActiveRecord::Migration.verbose = false
      ActiveRecord::Schema.define do
        create_table(:widgets, force: true) { it.string :name }
      end
      self.class.schema_loaded = true
    ensure
      ActiveRecord::Migration.verbose = previous_verbose if defined?(previous_verbose)
    end

    def assert_event(records, event)
      assert event_record?(records, event), "expected event #{event.inspect}"
    end

    def refute_event(records, event)
      refute event_record?(records, event), "expected no event #{event.inspect}"
    end

    def assert_logger_message(records, message)
      assert records.any? { it["event"] == "log" && it["message"] == message },
             "expected logger message #{message.inspect}"
    end

    def refute_logger_message_includes(records, fragment)
      refute records.any? { it["event"] == "log" && it["message"].to_s.include?(fragment) },
             records.inspect
    end

    def event_record?(records, event)
      records.any? { it["event"] == event }
    end

    def summary_record(records)
      summary = records.find { it["kind"] == "summary" && it["event"] == "request.completed" }
      return summary if summary

      flunk("expected request.completed summary in #{records.inspect}")
    end

    class << self
      attr_accessor :schema_loaded

      def schema_loaded? = !!schema_loaded
    end
  end
end
