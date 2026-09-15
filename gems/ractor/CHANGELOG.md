## Unreleased

## 1.1.5 - 2026-09-15

- Refresh the dependency lockset and require julewire-core 1.1.5.

## 1.1.4 - 2026-08-30

- Refresh the dependency lockset and require julewire-core 1.1.4.

## 1.1.3 - 2026-08-09

- Quiesce destination workers before process forks and reject forks with live
  Ractors instead of rebuilding unsafe inherited VM state.
- Serialize emit, close, and fork transitions; preserve terminal closure and
  keep interrupted worker teardown retryable.
- Require julewire-core 1.1.3.
- Refresh development tooling and compatibility locksets.

## 1.1.2 - 2026-08-02

- Refresh development and compatibility dependency locksets.

## 1.1.1 - 2026-07-26

- Refresh the tested dependency lockset.

## 1.1.0 - 2026-07-20

- Require finite request timeouts and bound destination worker startup and
  shutdown so lifecycle operations cannot wait forever.
- Harden queue accounting, fanout validation, worker stats, and Ractor-safe
  reply-timeout cleanup.
- Discard inherited Ractor handles before rebuilding destination workers in a
  forked child process.
- Normalize application emit input before strict bridge serialization while
  keeping integration-owned emits on a non-normalizing Symbol-key path.
- Require julewire-core 1.1.0.

## 1.0.1 - 2026-06-25

- Reserve ractor destination queue slots before send and roll them back on
  send failure.
- Count impossible queue-slot over-release events for destination health
  debugging.
- Require julewire-core 1.0.1.

## 1.0.0 - 2026-06-21

- Initial release: Ruby 4 ractor bridge, child-runtime forwarding, remote
  summaries, fanout, and ractor destination workers.
