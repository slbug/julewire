## Unreleased

## 1.0.1 - 2026-06-21

- Reserve ractor destination queue slots before send and roll them back on
  send failure.
- Count impossible queue-slot over-release events for destination health
  debugging.
- Require julewire-core 1.0.1.

## 1.0.0 - 2026-06-21

- Initial release: Ruby 4 ractor bridge, child-runtime forwarding, remote
  summaries, fanout, and ractor destination workers.
