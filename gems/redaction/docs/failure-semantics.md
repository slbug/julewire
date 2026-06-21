# Failure Semantics

Redaction is fail-closed at the record boundary.

Register redaction with core's default `on_error: :fail_closed` policy. If a
custom filter proc raises, the processor raises. Core treats that as a processor
failure and does not emit the original unredacted record. Core records the
failure in health and emits its contained failure record when possible.

The failure is record-level, not field-level. A failing custom filter loses the
record rather than keeping the record with only that one field unredacted.

The processor receives a `Julewire::RecordDraft` and applies its
whole-record transform through `transform_record!`, so cache invalidation and
lineage preservation stay inside core.
