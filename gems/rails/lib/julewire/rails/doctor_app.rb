# frozen_string_literal: true

require "cgi/escape"
require "json"
require "rack/request"
require "time"

module Julewire
  module Rails
    class DoctorApp
      CONTENT_TYPE = { "content-type" => "text/html; charset=utf-8" }.freeze
      JSON_TYPE = { "content-type" => "application/json; charset=utf-8" }.freeze
      SSE_TYPE = {
        "cache-control" => "no-cache",
        "content-type" => "text/event-stream; charset=utf-8"
      }.freeze
      TAIL_LIMIT = 50

      def initialize(runtime: Julewire, tail: nil)
        @runtime = runtime
        @tail = tail
      end

      def call(env)
        request = ::Rack::Request.new(env)
        case request.path_info
        when "", "/", "/doctor"
          html_response(render_doctor(request))
        when "/doctor.json"
          json_response(@runtime.doctor)
        when "/tail"
          html_response(render_tail(request))
        when "/tail.json"
          json_response(tail_records)
        when "/tail/events"
          sse_response(tail_events(request))
        else
          not_found_response
        end
      end

      private

      def html_response(body)
        [200, CONTENT_TYPE.dup, [body]]
      end

      def json_response(value)
        [200, JSON_TYPE.dup, [JSON.generate(value)]]
      end

      def sse_response(events)
        [200, SSE_TYPE.dup, events]
      end

      def not_found_response
        [404, CONTENT_TYPE.dup, ["not found"]]
      end

      def render_doctor(request)
        report = @runtime.doctor
        warning_items = report.fetch(:warnings).map do |warning|
          "<li><code>#{escape(warning.fetch(:code))}</code> #{escape(warning.fetch(:message))}</li>"
        end.join

        page(
          "Julewire Doctor",
          [
            "<p>Status: <strong>#{escape(report.fetch(:status))}</strong></p>",
            "<p>Level: <code>#{escape(report.dig(:runtime, :level))}</code></p>",
            "<p>Pipeline: <strong>#{escape(report.dig(:pipeline, :status))}</strong></p>",
            "<h2>Warnings</h2>",
            warning_items.empty? ? "<p>None</p>" : "<ul>#{warning_items}</ul>",
            nav_links(request, ["/tail", "Tail"], ["/doctor.json", "JSON"])
          ].join
        )
      end

      def render_tail(request)
        return page("Julewire Tail", "<p>Tail is not attached.</p>") unless @tail

        body = [
          "<p>#{@tail.health.fetch(:size)} / #{@tail.capacity} records</p>",
          [
            "<table><thead><tr><th>Severity</th><th>Event</th><th>Message</th></tr></thead>",
            %(<tbody data-tail-records data-tail-events-path="#{escape(app_path(request, "/tail/events"))}">),
            tail_rows,
            "</tbody></table>"
          ].join,
          tail_nav(request),
          tail_script
        ].join
        page("Julewire Tail", body)
      end

      def tail_rows
        tail_entries.reverse.map { tail_row(it) }.join
      end

      def tail_row(entry)
        record = entry.record
        [
          "<tr data-sequence=\"#{entry.sequence}\">",
          "<td><code>#{escape(record["severity"])}</code></td>",
          "<td><code>#{escape(record["event"])}</code></td>",
          "<td>#{escape(record["message"])}</td>",
          "</tr>"
        ].join
      end

      def tail_nav(request)
        nav_links(request, ["/doctor", "Doctor"], ["/tail.json", "JSON"])
      end

      def tail_records
        @tail ? @tail.records(limit: TAIL_LIMIT) : []
      end

      def tail_entries
        @tail ? @tail.entries(limit: TAIL_LIMIT) : []
      end

      def tail_events(request)
        return ["event: unavailable\ndata: {}\n\n"] unless @tail

        after = event_cursor(request)
        events = tail_entries.filter_map do |entry|
          next unless entry.sequence > after

          "id: #{entry.sequence}\nevent: record\ndata: #{JSON.generate(tail_event(entry))}\n\n"
        end
        events.empty? ? [": empty\nretry: 1000\n\n"] : ["retry: 1000\n\n", *events]
      end

      def event_cursor(request)
        value = request.get_header("HTTP_LAST_EVENT_ID")
        value = request.params["after"] if value.nil? || value.empty?
        Integer(value || 0)
      rescue ArgumentError, TypeError
        0
      end

      def tail_event(entry)
        {
          at: entry.at.iso8601(6),
          message: entry.record["message"],
          record: entry.record,
          sequence: entry.sequence
        }
      end

      def tail_script
        <<~HTML
          <script>
            (() => {
              const rows = document.querySelector("[data-tail-records]");
              if (!rows || !window.EventSource) return;
              const eventsPath = rows.dataset.tailEventsPath;
              if (!eventsPath) return;
              const seen = new Set(Array.from(rows.querySelectorAll("[data-sequence]")).map(row => row.dataset.sequence));
              const cell = value => {
                const td = document.createElement("td");
                td.textContent = value == null ? "" : String(value);
                return td;
              };
              const codeCell = value => {
                const td = document.createElement("td");
                const code = document.createElement("code");
                code.textContent = value == null ? "" : String(value);
                td.appendChild(code);
                return td;
              };
              const prepend = entry => {
                const sequence = String(entry.sequence);
                if (seen.has(sequence)) return;
                seen.add(sequence);
                const record = entry.record || {};
                const row = document.createElement("tr");
                row.dataset.sequence = sequence;
                row.appendChild(codeCell(record.severity));
                row.appendChild(codeCell(record.event));
                row.appendChild(cell(entry.message));
                rows.prepend(row);
              };
              const source = new EventSource(eventsPath);
              source.addEventListener("record", event => prepend(JSON.parse(event.data)));
            })();
          </script>
        HTML
      end

      def app_path(request, path)
        base = request.script_name.to_s
        base = "" if base == "/"
        "#{base}#{path}"
      end

      def nav_links(request, *links)
        %(<p>#{links.map { link_to(request, it.fetch(0), it.fetch(1)) }.join(" ")}</p>)
      end

      def link_to(request, path, label)
        %(<a href="#{escape(app_path(request, path))}">#{escape(label)}</a>)
      end

      def page(title, body)
        <<~HTML
          <!doctype html>
          <html>
          <head>
            <meta charset="utf-8">
            <title>#{escape(title)}</title>
            <style>
              body { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; margin: 2rem; color: #171717; }
              a { color: #0b5fff; margin-right: 1rem; }
              table { border-collapse: collapse; width: 100%; }
              th, td { border-bottom: 1px solid #ddd; padding: 0.45rem; text-align: left; vertical-align: top; }
            </style>
          </head>
          <body>
            <h1>#{escape(title)}</h1>
            #{body}
          </body>
          </html>
        HTML
      end

      def escape(value)
        ::CGI.escapeHTML(value.to_s)
      end
    end
  end
end
