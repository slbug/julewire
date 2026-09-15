## Unreleased

## 1.1.5 - 2026-09-15

- Refresh Karafka dependencies and require julewire-core 1.1.5.

## 1.1.4 - 2026-08-30

- Refresh the dependency lockset and require julewire-core 1.1.4.

## 1.1.3 - 2026-08-09

- Quiesce Julewire resources without emitting after Karafka pre-fork preparation.
- Test against Karafka 2.6 and remove reflective monitor-profile lookup.
- Require julewire-core 1.1.3.
- Refresh development tooling and compatibility locksets.

## 1.1.2 - 2026-08-02

- Refresh development and compatibility dependency locksets.

## 1.1.1 - 2026-07-26

- Refresh the tested dependency lockset.

## 1.1.0 - 2026-07-20

- Report unsupported WaterDrop message shapes through Karafka integration
  health instead of silently skipping propagation.
- Restore propagated context through owned carrier envelopes.
- Require julewire-core 1.1.0.

## 1.0.1 - 2026-06-25

- Default propagation carrier byte limits to 64 KiB and record health when
  oversized or malformed message carriers are ignored on restore.
- Require julewire-core 1.0.1.

## 1.0.0 - 2026-06-21

- Initial release: Karafka and WaterDrop event capture, message execution
  summaries, propagation carriers, and monitor health.
