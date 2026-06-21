# String Values

Structured key/value redaction is the primary path.

`string_values` defaults to `false`. When enabled, the processor also tries to
scrub embedded secrets inside string values.

```ruby
Julewire::Redaction.configure do |config|
  config.string_values = true
end
```

The string scrubber handles common opaque-string shapes:

- header lines such as `Authorization:`, `Cookie:`, `Set-Cookie:`, and
  `X-Api-Key:`
- JSON-like string pairs such as `"access_token": "abc"`
- query/form pairs such as `access_token=abc&scope=read`

This is defense-in-depth. It is not a JSON parser and it does not replace
structured key/value redaction.

String scrubbing scans the full string value before core output truncation. It
is therefore proportional to captured body size. Avoid pairing
`string_values: true` with unbounded request or response body capture unless the
volume and body sizes are known to be small.

Regexp filters disable the cheap string-key pre-scan, so every colon/equal style
string is checked against the pair scrubbers when `string_values` is enabled.

The matcher intentionally covers only simple string patterns. Escaped quotes,
unquoted or numeric JSON values, multiline serialized data, and custom formats
can remain unchanged unless the surrounding structured key is also redacted.

When `authorization_header` is true, `Authorization:` header lines are redacted
even if `authorization` is not present in the filter list.
