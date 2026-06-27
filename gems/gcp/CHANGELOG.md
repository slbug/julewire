## Unreleased

## 1.1.0 - 2026-07-20

- Keep Cloud Logging formatting and decoding aligned with the core record field
  taxonomy and deterministic trace/source parsing.
- Require julewire-core 1.1.0.

## 1.0.1 - 2026-06-25

- Replace the fallback backtrace regex with deterministic parsing so GCP source
  location inference stays boring under CodeQL.
- Require julewire-core 1.0.1.

## 1.0.0 - 2026-06-21

- Initial release: Google Cloud Logging formatter, trace fields, source
  locations, Error Reporting shape, and CLI transcode support.
