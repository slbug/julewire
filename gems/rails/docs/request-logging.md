# Request Logging

The request middleware replaces `Rails::Rack::Logger`, wraps each Rack request
in a Julewire execution scope, and emits one request summary when enabled.

Rails emits five Julewire record shapes:

| Source | Shape |
| --- | --- |
| Rails structured events | Point records such as `active_record.sql`. |
| `Rails.logger.*` | Point records with `event: "log"`. |
| Request boundary | One `request.completed` summary. |
| `Rails.error` | Explicit `rails.error` point records. |
| Rendered exception interceptor | Optional diagnostic point records. |

`Rails.logger` records intentionally do not honor user-supplied `kind`,
`execution`, `carry`, `attributes`, or `neutral` keys. Those keys are treated as
payload data so ordinary logger calls cannot forge execution identity,
propagation state, or formatter coordination fields.

Request ids, method, path, and remote IP stay in `context`. Rails-specific
routing and diagnostics such as controller, action, format, params, status,
filtered URL/path, timings, completion, and capture fields live under
`attributes.rails`.

Provider-neutral HTTP fields live in the record's `neutral` section for
formatters:

- `http.request.method`
- `url.full`
- `url.path`
- `user_agent.original`
- `client.address`
- `http.response.status_code`
- `http.response.body.size`

The request summary emits at Rack response completion when Rails/Rack exposes a
completion hook, or when the wrapped response body closes. If neither happens,
`request_summary_timeout` emits a `request.completion_timeout` warning point
with `completion_timeout_ms`. It does not finish the request summary from the
timeout thread; a later body close can still emit the normal summary.

`ActionController::Live` child-thread execution does not inherit Julewire
context by itself. Live needs an explicit bridge through Rails execution state.

Julewire Rails supports Rails' default
`config.action_dispatch.show_exceptions = :all`. `:rescuable` and `:none` let
some or all exceptions escape to the Rack server and are not supported modes for
Julewire Rails request logging.
