# Configuration

Rails config lives on `Julewire::Rails.config` and on
`config.julewire_rails` in a Rails application.

When Julewire owns `Rails.logger`, Rails logger calls are gated by
`Rails.logger.level`. They bypass core `Julewire.config.level` because the Rails
logger already applied its level check. Direct `Julewire.emit` and severity
helper calls still use core `Julewire.config.level`.

## Default Path

These defaults are intended for a normal Rails app:

| Option | Default | Purpose |
| --- | --- | --- |
| `logger` | `true` | Install Julewire as `Rails.logger`. |
| `request_middleware` | `true` | Wrap Rack requests in Julewire executions. |
| `request_summary` | `true` | Emit one `request.completed` summary per request. |
| `request_context` | `true` | Add request id, method, path, and remote IP to context. |
| `structured_events` | `true` | Subscribe to selected Rails structured events. |
| `error_reports` | `true` | Subscribe to `Rails.error` reports. |
| `source` | `"rails"` | Source value on Rails records. |
| `silence_log_subscribers` | `:auto` | Silence Rails default text subscribers when Julewire owns `Rails.logger`. |
| `replace_rack_logger` | `true` | Replace `Rails::Rack::Logger` with Julewire request middleware. |

## Common Knobs

| Option | Default | Purpose |
| --- | --- | --- |
| `carry_request_headers` | `false` | Explicit request-header list copied into `Julewire.carry`. |
| `request_exclude_prefixes` | `[]` | Request path prefixes that bypass Julewire request context and summaries. |
| `request_summary_timeout` | `30` | Seconds before warning that body close/completion is late. It does not finish the summary. |
| `request_capture.headers` | `false` | Add selected request headers to `attributes.rails` on summaries. |
| `request_capture.body` | `false` | Add request body fields to `attributes.rails` on summaries. |
| `response_capture.headers` | `false` | Add selected response headers to `attributes.rails` on summaries. |
| `response_capture.body` | `false` | Add response body fields to `attributes.rails` on summaries. |
| `filter_event_payloads` | `true` | Filter serialized object-event hashes with Rails parameter filters. |
| `rendered_exceptions` | `false` | Emit diagnostic rendered-exception point records in addition to summaries. |

Broad header capture (`*.headers = true`) skips common sensitive headers.
Explicit header lists are authoritative.

`structured_event_prefixes = nil` accepts all structured-event names. Use it
only when the app wants Julewire to consider every Rails event.

Capture sub-options:

| Option | Default | Purpose |
| --- | --- | --- |
| `*.headers` | `false` | `false`, `true`, or explicit header names. |
| `*.body` | `false` | `true` captures raw buffered bodies; `:json` parses bodies into `*_body_json`. |
| `*.body_bytes` | `65_536` | Body byte cap; `nil` means no cap. |
| `*.body_content_types` | `Julewire::Rack::Capture::BodyContentType::JSON_ONLY` | Media-type allowlist; `true` means all non-binary buffered bodies. |

## Structured Events

| Option | Default | Purpose |
| --- | --- | --- |
| `structured_event_prefixes` | `["action_controller.", "action_dispatch.", "active_record."]` | Rails event prefixes. |
| `structured_event_names` | `[]` | Exact event names to emit. |
| `structured_event_exclude_prefixes` | `[]` | Prefixes to suppress. |
| `structured_event_exclude_names` | `[]` | Exact names to suppress. |

`action_view.` is opt-in because Rails exposes every render start, partial,
collection, layout, and template as structured events.

```ruby
Julewire::Rails.configure do |config|
  config.structured_event_names = %w[action_view.render_template]
end
```

Example:

```ruby
Julewire::Rails.configure do |config|
  config.carry_request_headers = %w[traceparent tracestate]
  config.request_exclude_prefixes = ["/julewire"]
  config.response_capture.body = :json
  config.response_capture.body_content_types = %w[application/json]
end
```
