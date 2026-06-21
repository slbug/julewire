# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestRailsDoctorApp < Minitest::Test
    cover Julewire::Rails::DoctorApp

    def test_doctor_app_renders_doctor_html_and_json
      app = Julewire::Rails::DoctorApp.new

      status, headers, body = app.call("PATH_INFO" => "/doctor", "REQUEST_METHOD" => "GET")

      assert_equal 200, status
      assert_equal "text/html; charset=utf-8", headers.fetch("content-type")
      refute_predicate headers, :frozen?
      assert_includes body.join, "Julewire Doctor"
      assert_includes body.join, "href=\"/tail\""
      assert_includes body.join, "href=\"/doctor.json\""

      status, headers, body = app.call("PATH_INFO" => "/doctor.json", "REQUEST_METHOD" => "GET")

      assert_equal 200, status
      assert_equal "application/json; charset=utf-8", headers.fetch("content-type")
      refute_predicate headers, :frozen?
      report = JSON.parse(body.join)

      assert_equal "degraded", report.fetch("status")
      assert_equal "no_destinations", report.dig("warnings", 0, "code")
    end

    def test_doctor_app_renders_tail_when_attached
      app = doctor_app_with_attached_tail(capacity: 3)
      Julewire.info("hello", event: "tail.hello")

      status, _headers, body = app.call("PATH_INFO" => "/tail", "REQUEST_METHOD" => "GET")

      assert_equal 200, status
      assert_includes body.join, "tail.hello"
      assert_includes body.join, "hello"
      assert_includes body.join, "href=\"/doctor\""
      assert_includes body.join, "href=\"/tail.json\""
      assert_includes body.join, "data-tail-events-path=\"/tail/events\""
      assert_includes body.join, "new EventSource(eventsPath)"
    end

    def test_doctor_app_renders_tail_without_attachment
      status, _headers, body = Julewire::Rails::DoctorApp.new.call("PATH_INFO" => "/tail", "REQUEST_METHOD" => "GET")

      assert_equal 200, status
      assert_includes body.join, "Tail is not attached."
    end

    def test_doctor_app_returns_tail_json
      app = doctor_app_with_attached_tail(capacity: 3)
      Julewire.info("hello", event: "tail.hello")

      status, headers, body = app.call("PATH_INFO" => "/tail.json", "REQUEST_METHOD" => "GET")

      assert_equal 200, status
      assert_equal "application/json; charset=utf-8", headers.fetch("content-type")
      assert_equal "hello", JSON.parse(body.join).fetch(0).fetch("message")
    end

    def test_doctor_app_renders_derived_tail_messages
      app = doctor_app_with_attached_tail(capacity: 3)
      Julewire.emit(event: "rails.error", severity: :error, error: RuntimeError.new("123"))

      status, _headers, body = app.call("PATH_INFO" => "/tail", "REQUEST_METHOD" => "GET")

      assert_equal 200, status
      assert_includes body.join, "RuntimeError: 123"
    end

    def test_doctor_app_links_are_mount_path_aware
      app = doctor_app_with_attached_tail(capacity: 3)

      status, _headers, body = app.call(
        "PATH_INFO" => "/",
        "REQUEST_METHOD" => "GET",
        "SCRIPT_NAME" => "/julewire_tail"
      )

      assert_equal 200, status
      assert_includes body.join, "href=\"/julewire_tail/tail\""
      assert_includes body.join, "href=\"/julewire_tail/doctor.json\""

      status, _headers, body = app.call(
        "PATH_INFO" => "/tail",
        "REQUEST_METHOD" => "GET",
        "SCRIPT_NAME" => "/julewire_tail"
      )

      assert_equal 200, status
      assert_includes body.join, "href=\"/julewire_tail/doctor\""
      assert_includes body.join, "href=\"/julewire_tail/tail.json\""
      assert_includes body.join, "data-tail-events-path=\"/julewire_tail/tail/events\""
    end

    def test_doctor_app_streams_tail_events_after_cursor
      app = doctor_app_with_attached_tail(capacity: 3)
      Julewire.info("first", event: "tail.first")
      Julewire.info("second", event: "tail.second")

      status, headers, body = app.call(
        "HTTP_LAST_EVENT_ID" => "1",
        "PATH_INFO" => "/tail/events",
        "REQUEST_METHOD" => "GET"
      )

      assert_equal 200, status
      assert_equal "text/event-stream; charset=utf-8", headers.fetch("content-type")
      refute_predicate headers, :frozen?
      stream = body.join

      refute_includes stream, "tail.first"
      assert_includes stream, "id: 2"
      assert_includes stream, "tail.second"
    end

    def test_doctor_app_streams_empty_tail_event
      app = doctor_app_with_attached_tail(capacity: 3)

      status, headers, body = app.call(
        "PATH_INFO" => "/tail/events",
        "QUERY_STRING" => "after=9",
        "REQUEST_METHOD" => "GET"
      )

      assert_equal 200, status
      refute_predicate headers, :frozen?
      assert_includes body.join, ": empty"
    end

    def test_doctor_app_returns_not_found_for_unknown_paths
      status, headers, = Julewire::Rails::DoctorApp.new.call("PATH_INFO" => "/missing", "REQUEST_METHOD" => "GET")

      assert_equal 404, status
      refute_predicate headers, :frozen?
    end

    private

    def doctor_app_with_attached_tail(capacity:)
      tail = Julewire::Tail.attach!(capacity: capacity)
      Julewire::Rails::DoctorApp.new(tail: tail)
    end
  end
end
