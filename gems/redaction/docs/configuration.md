# Configuration

`Julewire::Redaction.configure` changes the defaults used by the registered
`:redaction` processor. Configure redaction before building the core pipeline,
or pass explicit options to `config.processors.use`.

```ruby
Julewire::Redaction.configure do |config|
  config.filters = Julewire::Redaction::DEFAULT_FILTERS + %i[session_id]
  config.mask = "[FILTERED]"
  config.string_values = false
end
```

## Defaults

| Setting | Default | Meaning |
| --- | --- | --- |
| `filters` | `Julewire::Redaction::DEFAULT_FILTERS` | Structured keys to redact. |
| `mask` | `"[FILTERED]"` | Replacement value. |
| `string_values` | `false` | Also scrub embedded secrets in string values. |
| `authorization_header` | `true` | Always redact `Authorization:` header lines when string scrubbing is enabled. |

`DEFAULT_FILTERS` combines the secret and PII profiles:

- auth keys: `access_token`, `refresh_token`, `id_token`, `client_secret`,
  `assertion`, `code_verifier`, `token`, `authorization`, `cookie`,
  `set_cookie`, `x_api_key`, `set-cookie`, `x-api-key`
- common secret keys: `api_key`, `password`, `passwd`, `private_key`, `secret`
- extra secret keys: `crypt`, `salt`, `certificate`, `otp`, `cvv`, `cvc`
- PII keys: `email`, `ssn`

Use `Julewire::Redaction::SECRET_FILTERS` without
`Julewire::Redaction::PII_FILTERS` when PII fields are allowed in your logs.

String and symbol filters are case-insensitive exact matches. Use regexes for
partial matching.

For traversal limits and per-processor overrides, see
[Advanced Configuration](advanced-configuration.md).
