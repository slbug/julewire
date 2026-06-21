## Unreleased

## 1.0.1 - 2026-06-21

- Harden bounded traversal, ingress copying, and carrier extraction against
  noisy or hostile record shapes.
- Keep normalized record constructors strict: symbol-key contracts validate
  instead of quietly normalizing pipeline-owned data.
- Default carrier extraction to the byte cap, report extraction status to
  integrations, reserve truncation metadata keys at field ingress, and keep
  custom normalization limits out of the thread-local copier pool.
- Keep output writes independent from flush/close lifecycle locking.

## 1.0.0 - 2026-06-21

- Initial release: execution-scoped structured logging, propagation, bounded
  serialization, processors, destinations, health, tail, doctor, and CLI.
