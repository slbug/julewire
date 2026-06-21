# Continuations

Rails continuation events run inside the Julewire job execution scope when the
execution callback is installed.

The job summary records these values under `attributes.active_job`:

- `continuation_steps_started`
- `continuation_steps_completed`
- `continuation_steps_interrupted`
- `continuation_steps_failed`
- `continuation_steps_skipped`
- `continuation_interruptions`
- `continuation_resumptions`
- `continuation_description`
- `continuation_interrupt_reason`
- `continuation_last_step`
- `continuation_last_step_cursor`
- `continuation_last_step_resumed`
- `continuation_last_step_state`
- `continuation_status`
