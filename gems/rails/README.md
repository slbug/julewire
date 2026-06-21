# Julewire Rails

Rails integration for Julewire.

It installs a Rails-compatible logger, wraps Rack requests in Julewire
execution scopes, subscribes to Rails structured events, and records Rails error
reports. It targets Rails 8.1 and newer.

## Quickstart

```ruby
gem "julewire-rails"
```

Configure a Julewire output or custom destination:

```ruby
Julewire.configure do |config|
  config.destinations.use(:default, output: $stdout)
  config.level = :info

  config.processors.prepend(
    :rails_parameter_filter,
    Rails.application.config.filter_parameters
  )
end
```

Or generate the initializer:

```sh
bin/rails generate julewire:install
```

Use normal Rails APIs:

```ruby
Rails.logger.info("booted")
Rails.logger.warn(message: "retrying", event: "payment.retry", payment_id: 123)
```

Default behavior:

- `Rails.logger.*` calls become Julewire point records.
- Each request gets one `request.completed` summary.
- Rails 8.1 structured events become machine point records.
- `Rails.error` reports become `rails.error` point records.
- Automatic request exceptions are owned by the request summary.
- Rails default text subscribers are silenced when Julewire installs the Rails
  logger.

Request context stays small: request id, method, path, and remote IP. Rails
routing, status, timings, completion, and optional capture fields live under
`attributes.rails`.

Rails filters structured event payloads before Julewire receives them.
Whole-record filtering for `Rails.logger` payloads and optional captured fields
is a Julewire processor policy; use the registered `:rails_parameter_filter`
processor when Rails' `filter_parameters` should apply to the full Julewire
record.

## Docs

- [Configuration](docs/configuration.md)
- [Advanced Configuration](docs/advanced-configuration.md)
- [Request Logging](docs/request-logging.md)
- [Events and Errors](docs/events-and-errors.md)
- [Capture and Filtering](docs/capture-and-filtering.md)
- [Lifecycle](docs/lifecycle.md)
- [Development](docs/development.md)

## Local Doctor

Mount the doctor app in development when you want a tiny health and tail view:

```ruby
tail = Julewire.dev!(tail: { capacity: 500 })
mount Julewire::Rails::DoctorApp.new(tail: tail) => "/julewire"
```

The mounted app serves `/doctor`, `/doctor.json`, `/tail`, `/tail.json`, and a
reconnecting `/tail/events` stream for the live tail page.

The mounted app exposes health, tail buffers, and request paths. Gate it with
environment, auth, IP rules, or an internal network boundary.

Exclude the mount path from request summaries so the live tail does not capture
its own polling requests:

```ruby
Julewire::Rails.configure do |config|
  config.request_exclude_prefixes = ["/julewire"]
end
```
