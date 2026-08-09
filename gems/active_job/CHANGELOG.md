## Unreleased

## 1.1.3 - 2026-08-09

- Refresh development tooling and compatibility locksets.

## 1.1.2 - 2026-08-02

- Refresh development and compatibility dependency locksets.

## 1.1.1 - 2026-07-26

- Refresh the tested dependency lockset.

## 1.1.0 - 2026-07-20

- Restore propagated context through owned carrier envelopes and keep job
  status summaries on Active Job's normal `StandardError` path.
- Require Julewire 1.1.0 internal gems.

## 1.0.1 - 2026-06-25

- Default propagation carrier byte limits to 64 KiB and record health when
  oversized or malformed job carriers are ignored on restore.
- Require julewire 1.0.1 internal gems.

## 1.0.0 - 2026-06-21

- Initial release: ActiveJob execution summaries, structured events,
  continuations, and propagation through job serialization.
