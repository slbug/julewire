# Security and Wire Keys

Julewire separates safety, privacy, and propagation. Core bounds output shape
and contains logger-path failures. It does not redact application data by
itself; redaction is processor policy.

## Trust Boundaries

Treat inbound carriers as trust-boundary data:

- Request headers are not restored automatically. Integrations choose explicit
  outbound carry headers.
- Job carriers live inside serialized job data. That is usually an internal
  queue boundary.
- Message headers can come from other producers. Use an integration-level
  carrier filter when topics accept external producers.

Carry is baggage-shaped: small propagated facts, not log content. Keep large
payloads in record `payload` or `attributes`, where processors and formatters
can apply policy before output.

## Capture and Redaction

Body and broad header capture are opt-in because they can contain secrets.
Framework parameter filtering may cover framework event payloads, but full
Julewire record filtering is a processor decision. Install a record-filtering
processor before enabling broad capture.

Health snapshots, internal error records, and invalid-severity diagnostics omit
raw exception messages and raw payloads. They carry safe coordinates such as
exception class, event, source, severity, phase, component, and timestamp.

## Wire Keys

| Key | Location | Purpose |
| --- | --- | --- |
| `julewire` | Generic carrier key and message header | Serialized propagation carrier. |
| `julewire.carrier` | Serialized job data | Propagation carrier inside job payloads. |
| `neutral` | record section | Neutral formatter-coordination fields. Default JSON strips it. |
| `_julewire_truncation` | Serialized hashes | Truncation metadata inserted by bounded serializers/transforms. |

These names are similar by design, but they live at different boundaries:
wire carriers move context across processes, `neutral` coordinates formatters
inside one record, and `_julewire_truncation` reports output
bounding.
