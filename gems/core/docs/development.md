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

## Contracts

Before changing public APIs or extension seams, read `docs/contracts.md`.
Breaking changes are allowed while Julewire is pre-release, but every change
should be explicit about whether it is changing application API, extension
contract, or private implementation.

## Coverage

Tests run with SimpleCov gates for line and branch coverage. Core keeps
remote-envelope contract coverage, not bridge implementation tests.

Race tests use queue handshakes where possible. Avoid sleep-based waits unless
the sleep is the thing under test.

## Lockfile

`Gemfile.lock` is committed for reproducible local development and CI. Runtime
dependencies still belong in the gemspec.

## Packaging Notes

The gemspec is the runtime dependency contract. `Gemfile` is for development
tooling.

The gem is a library. Executables are not part of the public package unless
they are intentionally moved under `exe/` and documented.
