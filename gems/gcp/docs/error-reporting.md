# Error Reporting

When a record contains an `error` hash with backtrace lines, the formatter
promotes those lines to top-level JSON payload field `stack_trace` for Cloud
Logging/Error Reporting ingestion.

The stack trace starts with the exception summary, includes nested causes, and
respects core's `error_backtrace_lines` setting. If
`error_backtrace_lines = 0`, core-shaped errors have no backtrace and the
formatter emits no `stack_trace`.

When `stack_trace` is promoted, nested `julewire.error.backtrace` fields are
removed to avoid carrying the same stack twice in one log entry. Exception
class, message, and cause metadata remain in `julewire.error`.

If the record has no message and no HTTP-derived message can be derived, the
top-level `message` uses the exception summary, such as
`RuntimeError: boom`.

When no explicit `payload.gcp.source_location` is present, the formatter first
uses neutral `code.*` fields from the record's `neutral` section, then infers
`logging.googleapis.com/sourceLocation` from the first error backtrace frame.

References:

- Google Cloud Logging structured logging:
  https://docs.cloud.google.com/logging/docs/structured-logging
- Google Cloud Logging `LogEntry`:
  https://docs.cloud.google.com/logging/docs/reference/v2/rest/v2/LogEntry
- Google Cloud Error Reporting log formatting:
  https://docs.cloud.google.com/error-reporting/docs/formatting-error-messages
