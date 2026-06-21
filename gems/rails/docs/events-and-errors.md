# Events and Errors

Rails 8.1 structured events are subscribed through `Rails.event`. Controller
start/completion events enrich the request summary. Framework events such as SQL
and render notifications are emitted as point records.

Rails default text log subscribers are silenced by default when Julewire owns the
Rails logger. Anything that still reaches `Rails.logger` is treated as a logger
call, not parsed as duplicate framework text.

To keep Rails' default logger output and use Julewire only for request summaries
or structured-event records:

```ruby
Julewire::Rails.configure do |config|
  config.logger = false
  config.request_middleware = true
  config.structured_events = true
end
```

When `request_summary` is enabled, rendered 4xx/5xx request errors are attached
to `request.completed`. The summary includes the Rails response status,
`error_class`, `rescue_response`, and `rescue_template`, plus the core-shaped
exception.

Request-error summary severity inherits Rails'
`action_dispatch.debug_exception_log_level`. Julewire does not derive this
severity from the status code.

Backtrace policy is owned by core:

```ruby
Julewire.configure do |config|
  config.error_backtrace_lines = 0
end
```

Set `rendered_exceptions = true` only when you want an additional diagnostic
point record from `ActionDispatch::DebugExceptions` alongside the summary-owned
request error.

`Rails.error` remains a separate source for explicit application reports,
handled reports, jobs, and framework errors that are not owned by a request
summary. Julewire records those as `rails.error` and shapes the exception
through core's exception serializer.
