# Development

Install dependencies:

```sh
bundle install
```

Run the default checks:

```sh
bundle exec rake
```

The default task runs:

- Minitest
- RuboCop
- Flay
- Debride
- Bundler Audit

## Coverage

Tests can run with SimpleCov:

```sh
COVERAGE=true bundle exec rake test
```

The gem supports Ruby 4.0 and newer. Tests exercise the Ruby 4.0
`Ractor::Port` bridge directly.

## Lockfile

`Gemfile.lock` is committed for reproducible local development and CI. Runtime
dependencies still belong in the gemspec.

## Packaging Notes

The gemspec is the runtime dependency contract. `Gemfile` is for development
tooling and the local path dependency on `julewire-core`.
