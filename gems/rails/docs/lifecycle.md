# Lifecycle

When `lifecycle_hooks` is enabled, the Railtie installs an at-exit drain hook
that flushes and closes Julewire with `shutdown_timeout`.

It also registers a Rails `ActiveSupport::ForkTracker` after-fork hook that:

- calls `Julewire.after_fork!`
- resets request-summary timeout scheduler state
- clears request-error ownership state

This covers Rails process forks that go through Rails' fork tracker.

Custom destinations still own queue, retry, delivery, and reopen behavior. The
Rails hook only gives them lifecycle opportunities.

`require_output` checks after Rails initializers that Julewire has at least one
configured destination when Julewire owns `Rails.logger`.

| Value | Behavior |
| --- | --- |
| `:warn` | Warn, but allow no-output mode. |
| `:raise` | Fail boot if no output is configured. |
| `false` | Do not check. |
