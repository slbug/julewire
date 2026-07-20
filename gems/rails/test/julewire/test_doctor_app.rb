# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestRailsDoctorApp < Minitest::Test
    cover Julewire::Rails::DoctorApp
    def test_doctor_app_renders_doctor_html_and_json
      app = Julewire::Rails::DoctorApp.new

      status, headers, body = call_doctor_app(app, path: "/doctor")

      assert_equal 200, status
      assert_equal "text/html; charset=utf-8", headers.fetch("content-type")
      refute_predicate headers, :frozen?
      assert_includes body.join, "Julewire Doctor"
      assert_includes body.join, "<title>Julewire Doctor</title>"
      assert_includes body.join, "href=\"/tail\""
      assert_includes body.join, "href=\"/doctor.json\""
      assert_includes body.join, "</a> <a"
      assert_includes body.join, ">Tail</a>"
      assert_includes body.join, ">JSON</a>"

      status, headers, body = call_doctor_app(app, path: "/doctor.json")

      assert_equal 200, status
      assert_equal "application/json; charset=utf-8", headers.fetch("content-type")
      refute_predicate headers, :frozen?
      report = JSON.parse(body.join)

      assert_equal "degraded", report.fetch("status")
      assert_equal "no_destinations", report.dig("warnings", 0, "code")
    end

    def test_doctor_app_renders_empty_mount_root_as_doctor
      app = Julewire::Rails::DoctorApp.new

      status, _headers, body = call_doctor_app(app, path: "")

      assert_equal 200, status
      assert_includes body.join, "<h1>Julewire Doctor</h1>"
    end

    def test_doctor_app_escapes_doctor_report_fields
      runtime = Object.new
      runtime.define_singleton_method(:doctor) do
        {
          pipeline: { status: "ok & wired" },
          runtime: { level: "<debug>" },
          status: "<degraded>",
          warnings: [
            { code: "warn<1>", message: "bad & loud" }
          ]
        }
      end
      app = Julewire::Rails::DoctorApp.new(runtime: runtime)

      status, _headers, body = call_doctor_app(app, path: "/doctor")
      html = body.join

      assert_equal 200, status
      assert_includes html, "Status: <strong>&lt;degraded&gt;</strong>"
      assert_includes html, "Level: <code>&lt;debug&gt;</code>"
      assert_includes html, "Pipeline: <strong>ok &amp; wired</strong>"
      assert_includes html, "<h2>Warnings</h2>"
      assert_includes html, "<ul><li><code>warn&lt;1&gt;</code> bad &amp; loud</li></ul>"
      assert_includes html, "<li><code>warn&lt;1&gt;</code> bad &amp; loud</li>"
      refute_includes html, "[\"<li>"
      refute_includes html, "<degraded>"
      refute_includes html, "warn<1>"
    end

    def test_doctor_app_uses_top_level_cgi_escape
      runtime = Object.new
      runtime.define_singleton_method(:doctor) do
        {
          pipeline: { status: "<ok>" },
          runtime: { level: "info" },
          status: "ok",
          warnings: []
        }
      end
      shadow = Module.new
      shadow.define_singleton_method(:escapeHTML) { |_value| raise "nested CGI must not be used" } # rubocop:disable Naming/MethodName

      with_temporary_constant(Julewire::Rails, :CGI, shadow) do
        _status, _headers, body = call_doctor_app(
          Julewire::Rails::DoctorApp.new(runtime: runtime),
          path: "/doctor"
        )

        assert_includes body.join, "Pipeline: <strong>&lt;ok&gt;</strong>"
      end
    end

    def test_doctor_app_renders_empty_warning_state
      runtime = Object.new
      runtime.define_singleton_method(:doctor) do
        {
          pipeline: { status: "ok" },
          runtime: { level: "info" },
          status: "ok",
          warnings: []
        }
      end
      app = Julewire::Rails::DoctorApp.new(runtime: runtime)

      status, _headers, body = call_doctor_app(app, path: "/doctor")
      html = body.join

      assert_equal 200, status
      assert_includes html, "<h2>Warnings</h2><p>None</p>"
      refute_includes html, "<ul>"
    end

    def test_doctor_app_renders_tail_when_attached
      app = doctor_app_with_attached_tail(capacity: 3)
      Julewire.info("hello", event: "tail.hello")

      status, _headers, body = call_doctor_app(app, path: "/tail")
      html = body.join

      assert_equal 200, status
      assert_includes html, "tail.hello"
      assert_includes html, "hello"
      assert_includes html, "1 / 3 records"
      assert_includes html, "<title>Julewire Tail</title>"
      assert_includes html, "href=\"/doctor\""
      assert_includes html, "href=\"/tail.json\""
      assert_includes html, ">Doctor</a>"
      assert_includes html, ">JSON</a>"
      assert_includes html, "<table><thead><tr><th>Severity</th><th>Event</th><th>Message</th></tr></thead>"
      assert_includes html, "data-tail-events-path=\"/tail/events\""
      assert_includes html, "new EventSource(eventsPath)"
      assert_includes html, "<tr data-sequence=\"1\">"
      assert_includes html, "<td><code>info</code></td>"
      assert_includes html, "<td><code>tail.hello</code></td>"
      assert_includes html, "<td>hello</td>"
      assert_includes html, "</tr>"
      assert_includes html, "</tbody></table>"
    end

    def test_doctor_app_escapes_tail_rows
      app = doctor_app_with_attached_tail(capacity: 3)
      Julewire.warn("<hello>", event: "tail.<event>")

      status, _headers, body = call_doctor_app(app, path: "/tail")
      html = body.join

      assert_equal 200, status
      assert_includes html, "<td><code>warn</code></td>"
      assert_includes html, "<td><code>tail.&lt;event&gt;</code></td>"
      assert_includes html, "<td>&lt;hello&gt;</td>"
      refute_includes html, "tail.<event>"
      refute_includes html, "<td><hello></td>"
    end

    def test_doctor_app_renders_newest_tail_rows_first
      app = doctor_app_with_attached_tail(capacity: 3)
      Julewire.info("first", event: "tail.first")
      Julewire.info("second", event: "tail.second")

      _status, _headers, body = call_doctor_app(app, path: "/tail")
      html = body.join

      assert_operator html.index("tail.second"), :<, html.index("tail.first")
    end

    def test_doctor_app_renders_tail_without_attachment
      status, _headers, body = call_doctor_app(path: "/tail")

      assert_equal 200, status
      assert_includes body.join, "<title>Julewire Tail</title>"
      assert_includes body.join, "Tail is not attached."
    end

    def test_doctor_app_returns_tail_json
      app = doctor_app_with_attached_tail(capacity: 3)
      Julewire.info("hello", event: "tail.hello")

      status, headers, body = call_doctor_app(app, path: "/tail.json")

      assert_equal 200, status
      assert_equal "application/json; charset=utf-8", headers.fetch("content-type")
      assert_equal "hello", JSON.parse(body.join).fetch(0).fetch("message")
    end

    def test_doctor_app_returns_empty_tail_json_without_attachment
      status, headers, body = call_doctor_app(path: "/tail.json")

      assert_equal 200, status
      assert_equal "application/json; charset=utf-8", headers.fetch("content-type")
      assert_equal [], JSON.parse(body.join)
    end

    def test_doctor_app_renders_derived_tail_messages
      app = doctor_app_with_attached_tail(capacity: 3)
      Julewire.emit(event: "rails.error", severity: :error, error: RuntimeError.new("123"))

      status, _headers, body = call_doctor_app(app, path: "/tail")

      assert_equal 200, status
      assert_includes body.join, "RuntimeError: 123"
    end

    def test_doctor_app_links_are_mount_path_aware
      app = doctor_app_with_attached_tail(capacity: 3)

      status, _headers, body = call_doctor_app(app, path: "/", script_name: "/julewire_tail")

      assert_equal 200, status
      assert_includes body.join, "href=\"/julewire_tail/tail\""
      assert_includes body.join, "href=\"/julewire_tail/doctor.json\""

      status, _headers, body = call_doctor_app(app, path: "/tail", script_name: "/julewire_tail")

      assert_equal 200, status
      assert_includes body.join, "href=\"/julewire_tail/doctor\""
      assert_includes body.join, "href=\"/julewire_tail/tail.json\""
      assert_includes body.join, "data-tail-events-path=\"/julewire_tail/tail/events\""
    end

    def test_doctor_app_escapes_mounted_paths
      app = doctor_app_with_attached_tail(capacity: 3)

      [
        {
          path: "/tail",
          includes: ["data-tail-events-path=\"/julewire&quot;&lt;tail&gt;/tail/events\""],
          excludes: ["data-tail-events-path=\"/julewire\"<tail>/tail/events\""]
        },
        {
          path: "/",
          includes: ["href=\"/julewire&quot;&lt;tail&gt;/tail\""],
          excludes: ["href=\"/julewire\"<tail>/tail\""]
        }
      ].each do |expectation|
        assert_doctor_body(app, script_name: "/julewire\"<tail>", **expectation)
      end
    end

    def test_doctor_app_limits_tail_json_and_rows
      app = doctor_app_with_attached_tail(capacity: 60)
      60.times { Julewire.info("message #{it}", event: "tail.#{it}") }

      status, _headers, body = call_doctor_app(app, path: "/tail.json")

      assert_equal 200, status
      assert_equal 50, JSON.parse(body.join).length

      status, _headers, body = call_doctor_app(app, path: "/tail")

      assert_equal 200, status
      assert_equal 50, body.join.scan("<tr data-sequence=").length
    end

    def test_doctor_app_mount_path_normalizes_slash_script_name
      app = doctor_app_with_attached_tail(capacity: 3)

      assert_doctor_body(app, path: "/", script_name: "/", includes: ["href=\"/tail\""], excludes: ["href=\"//tail\""])
    end

    def test_doctor_app_streams_tail_events_after_cursor
      app = doctor_app_with_attached_tail(capacity: 3)
      Julewire.info("first", event: "tail.first")
      Julewire.info("second", event: "tail.second")

      status, headers, body = call_doctor_app(app, path: "/tail/events", last_event_id: "1")

      assert_equal 200, status
      assert_equal "text/event-stream; charset=utf-8", headers.fetch("content-type")
      refute_predicate headers, :frozen?
      assert_true(body.all?(String))
      assert_equal "retry: 1000\n\n", body.fetch(0)
      assert_equal 2, body.length
      stream = body.join

      refute_includes stream, "tail.first"
      assert_includes stream, "id: 2"
      assert_includes stream, "tail.second"

      event = JSON.parse(stream.lines.grep(/\Adata: /).fetch(0).delete_prefix("data: "))

      assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}(?:Z|[+-]\d{2}:\d{2})\z/, event.fetch("at"))
      assert_equal "second", event.fetch("message")
      assert_equal 2, event.fetch("sequence")
      assert_equal "tail.second", event.dig("record", "event")
      assert_equal event.fetch("record").fetch("message"), event.fetch("message")
    end

    def test_doctor_app_streams_tail_events_after_query_cursor
      app = doctor_app_with_attached_tail(capacity: 3)
      Julewire.info("first", event: "tail.first")
      Julewire.info("second", event: "tail.second")

      status, _headers, body = call_doctor_app(app, path: "/tail/events", query_string: "after=1")

      assert_equal 200, status
      stream = body.join

      refute_includes stream, "tail.first"
      assert_includes stream, "id: 2"
      assert_includes stream, "tail.second"
    end

    def test_doctor_app_empty_last_event_id_falls_back_to_query_cursor
      app = doctor_app_with_attached_tail(capacity: 3)
      Julewire.info("first", event: "tail.first")
      Julewire.info("second", event: "tail.second")

      _status, _headers, body = call_doctor_app(
        app,
        path: "/tail/events",
        query_string: "after=1",
        last_event_id: ""
      )
      stream = body.join

      refute_includes stream, "tail.first"
      assert_includes stream, "tail.second"
    end

    def test_doctor_app_invalid_event_cursor_starts_at_zero
      app = doctor_app_with_attached_tail(capacity: 3)
      Julewire.info("first", event: "tail.first")

      _status, _headers, body = call_doctor_app(
        app,
        path: "/tail/events",
        query_string: "after=9",
        last_event_id: "not-an-integer"
      )

      assert_includes body.join, "tail.first"
    end

    def test_doctor_app_invalid_event_cursor_does_not_include_sequence_zero
      entry = Data.define(:sequence, :at, :record).new(
        0,
        Time.utc(2026, 1, 1),
        { "event" => "tail.zero", "message" => "zero", "severity" => "info" }
      )
      tail = Object.new
      tail.define_singleton_method(:entries) { |**| [entry] }
      app = Julewire::Rails::DoctorApp.new(tail: tail)

      _status, _headers, body = call_doctor_app(app, path: "/tail/events", last_event_id: "not-an-integer")

      assert_includes body.join, ": empty"
      refute_includes body.join, "tail.zero"
    end

    def test_doctor_app_streams_tail_events_without_message
      app = doctor_app_with_attached_tail(capacity: 3)
      Julewire.emit(event: "tail.event_only")

      _status, _headers, body = call_doctor_app(app, path: "/tail/events")

      event = JSON.parse(body.join.lines.grep(/\Adata: /).fetch(0).delete_prefix("data: "))

      assert_true event.key?("message")
      assert_nil event.fetch("message")
      assert_equal "tail.event_only", event.dig("record", "event")
    end

    def test_doctor_app_streams_unavailable_tail_event_without_attachment
      status, headers, body = call_doctor_app(path: "/tail/events")

      assert_equal 200, status
      assert_equal "text/event-stream; charset=utf-8", headers.fetch("content-type")
      assert_equal ["event: unavailable\ndata: {}\n\n"], body
    end

    def test_doctor_app_streams_empty_tail_event
      app = doctor_app_with_attached_tail(capacity: 3)

      status, headers, body = call_doctor_app(app, path: "/tail/events", query_string: "after=9")

      assert_equal 200, status
      refute_predicate headers, :frozen?
      assert_includes body.join, ": empty"
    end

    def test_doctor_app_returns_not_found_for_unknown_paths
      status, headers, body = call_doctor_app(path: "/missing")

      assert_equal 404, status
      assert_equal "text/html; charset=utf-8", headers.fetch("content-type")
      refute_predicate headers, :frozen?

      assert_equal ["not found"], body
    end

    private

    def doctor_app_with_attached_tail(capacity:)
      tail = Julewire::Tail.attach!(capacity: capacity)
      Julewire::Rails::DoctorApp.new(tail: tail)
    end

    def call_doctor_app(
      app = Julewire::Rails::DoctorApp.new,
      path:,
      script_name: nil,
      query_string: nil,
      last_event_id: nil
    )
      env = { "PATH_INFO" => path, "REQUEST_METHOD" => "GET" }
      env["SCRIPT_NAME"] = script_name if script_name
      env["QUERY_STRING"] = query_string if query_string
      env["HTTP_LAST_EVENT_ID"] = last_event_id if last_event_id
      app.call(env)
    end

    def assert_doctor_body(app, path:, includes:, script_name: nil, excludes: [])
      status, _headers, body = call_doctor_app(app, path:, script_name:)
      html = body.join

      assert_equal 200, status
      includes.each { assert_includes html, it }
      excludes.each { refute_includes html, it }
    end
  end
end
