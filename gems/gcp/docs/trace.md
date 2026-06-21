# Trace

The formatter exposes the trace header names it needs as:

```ruby
Julewire::GCP::CARRY_REQUEST_HEADERS
```

Put selected headers into Julewire carry before emitting records:

```ruby
headers = {
  "traceparent" => "00-...",
  "tracestate" => "...",
  "x-cloud-trace-context" => "..."
}

Julewire.with_execution(type: :request, id: "request-1") do
  Julewire.carry.add(http: { request_headers: headers })
  Julewire.emit(message: "handled")
end
```

By default the formatter looks for request headers at
`carry.http.request_headers`, then checks `payload.request_headers` and
`context.request_headers`. It understands W3C `traceparent` first, then Google
`x-cloud-trace-context`.

`tracestate` is carried with `traceparent`, but Cloud Logging special fields do
not use it directly. If `project_id` is configured, a bare trace ID is expanded
to:

```text
projects/[PROJECT-ID]/traces/[TRACE-ID]
```

Already-expanded trace resource names are left unchanged.

You can point trace extraction at different record paths when another
integration or processor stores trace facts elsewhere:

```ruby
Julewire::GCP::Formatter.new(
  project_id: "my-project",
  trace_id_path: %i[context trace_id],
  span_id_path: %i[context span_id],
  trace_sampled_path: %i[context trace_sampled]
)
```
