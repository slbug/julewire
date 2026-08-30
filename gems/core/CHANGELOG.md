## Unreleased

## 1.1.4 - 2026-08-30

- Refresh the development dependency lockset.

## 1.1.3 - 2026-08-09

- Add fail-loud pre-fork hooks with shared timeout budgets and reverse rollback.
- Refresh development tooling and compatibility locksets.

## 1.1.2 - 2026-08-02

- Refresh development and compatibility dependency locksets.

## 1.1.1 - 2026-07-26

- Refresh the tested dependency lockset.

## 1.1.0 - 2026-07-20

- Make carrier extraction status public via `Carrier::Extracted` and rename the
  convenience reader to `extract_envelope`.
- Enforce recursive Symbol keys for owned records and protocols; reject invalid
  processor results and malformed propagation sections instead of normalizing
  or ignoring them.
- Require canonical lowercase severity Symbols while retaining case-insensitive
  String and standard-library Logger integer ingress.
- Harden bounded serialization, `RecordDraft` isolation/finalization, and
  processor, summary, and lifecycle failure health; remove reusable bounded
  transforms and the undocumented `freeze_sections` mode.
- Remove `Julewire::Testing::Contracts` and `Julewire::Testing::Chaos`; the
  testing API now contains only capture and null-output observation fixtures.
- Remove the generic deadline-scheduler SPI; main-process integrations now use
  only the process-owned shared scheduler, leaving Ractor-safe timeout ownership
  to the Ractor integration.

## 1.0.1 - 2026-06-25

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
