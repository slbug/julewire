# Advanced Configuration

## Runtime Configuration

`configure` yields a mutable `Julewire::Core::Configuration` builder, then
stores a frozen copy with frozen registry containers. Core builds and installs
the staged pipeline against that frozen copy before swapping runtime state.

The active configuration containers exposed by `Julewire.config` and
`Julewire.labels` are read-only. Mutating runtime configuration after the fact
is unsupported. Call `Julewire.configure` again.

User-supplied destination formatter, encoder, output, and processor instances
are shared by reference. Processors, formatters, and encoders must be stateless
or otherwise reentrant; core does not synchronize them. Direct outputs are
wrapped with a per-destination mutex.

When a reconfigure reuses the same output or destination object, core keeps that
resource open for the new active pipeline and skips teardown through the old
pipeline. Replacing an output object still flushes or closes the previous one
according to its `close_output` setting.

`configure` is non-reentrant. Do not call runtime APIs such as `emit`,
`configure`, or `reset!` from inside a `configure` block.

## Failure and Drop Callbacks

`on_failure` receives contained `StandardError` instances from Julewire's own
logging path, plus one metadata hash. Metadata may include `:phase`,
`:record_metadata`, `:action`, and output class when known.

`on_drop` receives a symbolic reason for operational drops after processing has
started, such as oversized encoded records, formatter errors, encoder errors,
output failures, output rejections, custom destination failures/rejections, and
post-close `:runtime_closed` drops.

Level filtering and intentional no-output mode are counted in health but do not
call `on_drop`; those are configuration or policy outcomes, not output-loss
callbacks. Drop callbacks receive the same metadata-hash shape.

Callbacks are best effort. Exceptions raised by callbacks are swallowed and
counted where health can report them. Core health keeps those counters small;
callbacks that need richer diagnostics should record them locally.
The recursion guard uses fiber storage, so work handed to a child fiber from
inside a callback stays inside the same callback-suppression scope.

Callbacks are called with two positional arguments:
`on_failure.call(error, metadata)` and `on_drop.call(reason, metadata)`.
Core uses Ruby duck typing at configuration time; it only requires callback
objects to respond to `call`. Arity or keyword mistakes are contained when the
callback is invoked and are counted as callback failures in health.

Drop counters count every dropped record. Use health counters for alerting;
callback frequency is intentionally not a metric. Applications that need
callback throttling should implement it in the callback.

## Non-Standard Exception Summaries

`emit_non_standard_exception_summaries` defaults to `false`.

When false, core suppresses execution summaries while unwinding exceptions
outside `StandardError`, such as `SystemExit` and signal exceptions. When true,
core tries to emit those summaries too.

The application exception still wins; execution boundaries re-raise application
exits after recording what they can.
