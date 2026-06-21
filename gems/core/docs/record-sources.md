# Record Sources

Core records come from several broad source classes. Integrations can map
their own runtime surfaces into these shapes, but core does not know those
runtime APIs.

| Source | Julewire shape | Rule |
| --- | --- | --- |
| External event | Point record | Map runtime event data into `event`, `source`, `context`, and `attributes`; leave `payload` for caller data. |
| Logger call | Point record, usually `event: "log"` | Treat it as a real log item. Do not parse or deduplicate text. |
| Execution boundary | Summary record | Use `with_execution` and emit one final summary when enabled. |
| Error report | Point record | Map explicit error reports as point records with current context. |
| Rendered/runtime exception | Point record | Map structured exception surfaces. Do not parse human exception text. |

Core only normalizes, processes, formats, and writes records. Integrations own
subscription, suppression of duplicate upstream emitters, and any
runtime-specific policy.
