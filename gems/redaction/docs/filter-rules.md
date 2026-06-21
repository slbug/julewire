# Filter Rules

The redaction processor walks the normalized Julewire record and replaces
matching values.

Matching applies wherever the key appears, including `execution`, `context`,
`carry`, `neutral`, `attributes`, `labels`, `payload`, `metrics`, and `error`.
Top-level record container fields keep their required Julewire shape even if a
filter matches the section name.

## Exact Keys

String and symbol filters are exact, case-insensitive key matches:

```ruby
Julewire::Redaction.configure do |config|
  config.filters = %i[password api_key]
end
```

This redacts `password` and `api_key`, but not `old_password_hash` unless that
key is listed or matched by a regex.

## Nested Keys

Dot notation scopes a filter to a nested structured path:

```ruby
Julewire::Redaction.configure do |config|
  config.filters = ["credit_card.code"]
end
```

This redacts:

```ruby
{ credit_card: { code: "123" } }
```

It does not redact:

```ruby
{ file: { code: "123" } }
```

## Regex Rules

Use regexes for deliberate partial matching:

```ruby
Julewire::Redaction.configure do |config|
  config.filters = Julewire::Redaction::DEFAULT_FILTERS + [/password|secret/i]
end
```

Regexes match leaf keys. Use `Julewire::Redaction.path(...)` for path-aware
regexes that match a dotted structured path:

```ruby
Julewire::Redaction.configure do |config|
  config.filters = [Julewire::Redaction.path(/user.email/i)]
end
```

Use `Julewire::Redaction::SECRET_FILTERS` when the default PII profile is too
broad for your application.

## Proc Rules

Proc filters follow Rails' shape:

- 2-arity procs receive `key, value`
- 3-arity procs receive `key, value, original_record`

`original_record` is the root normalized record hash.

```ruby
Julewire::Redaction.configure do |config|
  config.filters = [
    lambda do |key, value|
      value.replace("[FILTERED]") if key == "customer_note" && value.include?("ssn=")
    end
  ]
end
```

Proc rules mutate a duplicate of string scalar values. If a proc raises, the
record is not emitted.

String filters with dots are path-aware. Raw regexes are key matchers unless
wrapped with `Julewire::Redaction.path(...)`.
