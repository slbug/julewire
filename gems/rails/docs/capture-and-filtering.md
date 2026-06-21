# Capture and Filtering

Header and body capture is off by default. Captured fields are summary
enrichment fields under `attributes.rails`.

Response body capture reads the buffered `ActionDispatch::Response` body from
`process_action.action_controller`. It does not consume or replace the Rack
response body. File and stream-like responses are skipped. Streaming response
bodies are not captured. Mounted Rack apps still get request summaries, but
header and body capture requires a Rails controller `process_action` event.

```ruby
Julewire::Rails.configure do |config|
  config.response_capture.body = true
  config.response_capture.body_bytes = nil
  config.response_capture.body_content_types = %w[application/json]
end
```

Use `body = :json` to parse captured JSON into `request_body_json` or
`response_body_json` instead of storing the raw body string. Truncated bodies
are not parsed; invalid JSON records `*_body_parse_error`.
When `body_bytes` is `nil`, `:json` mode parses the full captured body before
core serialization limits apply.

Captured response summaries include:

- `response_body`
- `response_body_json`
- `response_body_parse_error`
- `response_body_bytes`
- `response_body_truncated`

`*_body_bytes` is the content length when the framework provides it; otherwise
it is the number of bytes observed while capturing.

Request and response headers use `false`, `true`, or an explicit header list:

```ruby
Julewire::Rails.configure do |config|
  config.request_capture.headers = true
  config.response_capture.headers = %w[content-type x-request-id]
  config.request_capture.body = true
  config.request_capture.body_bytes = 65_536
end
```

When header capture is `true`, Julewire omits common sensitive headers such as
`authorization`, `cookie`, `set-cookie`, `proxy-authorization`, and
`x-api-key`. Use an explicit header list if the application deliberately wants
one of those fields.

Captured request summaries can include:

- `request_headers`
- `response_headers`
- `request_body`
- `request_body_json`
- `request_body_parse_error`
- `request_body_bytes`
- `request_body_truncated`

Use processors before enabling broad header/body capture in an application with
sensitive data.

Body capture is gated by media type. The default captures `application/json`
and `application/*+json` vendor media types. `true` means every non-file,
buffered candidate. Binary media types such as `application/octet-stream`,
images, audio, video, fonts, zip, gzip, and PDF are skipped even when body
content types are set to `true`.

Rails filters hash-based `Rails.event` payloads before subscribers receive
them. Object event payloads are different: Rails passes the object through, and
subscribers that serialize it must filter the serialized fields. Julewire Rails
filters serialized object-event hashes with
`Rails.application.filter_parameters` by default.

For whole-record filtering, Rails' parameter filter can be installed as a
Julewire processor:

```ruby
Julewire.configure do |config|
  config.processors.prepend(
    :rails_parameter_filter,
    Rails.application.config.filter_parameters
  )
end
```

Record container fields such as `payload`, `attributes`, and `context` keep
their Julewire shape even when a filter matches the section name.

Filtering layers:

| Layer | Scope |
| --- | --- |
| Rails event filtering | Serialized object event payloads before the Julewire record is built. |
| `ParameterFilterProcessor` | Whole Julewire records using Rails parameter filter rules. |
| Custom processors | Whole Julewire records using application policy. |

If more than one whole-record processor is installed, normal Julewire processor
order decides precedence.
