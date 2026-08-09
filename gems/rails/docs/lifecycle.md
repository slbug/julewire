# Lifecycle

When `lifecycle_hooks` is enabled, the Railtie installs an at-exit drain hook
that flushes and closes Julewire with `shutdown_timeout`.

It also registers a Rails `ActiveSupport::ForkTracker` after-fork hook that:

- calls `Julewire.after_fork!`
- resets request-summary timeout scheduler state
- clears request-error ownership state

This covers Rails process forks that go through Rails' fork tracker.

Rails' tracker exposes only the after-fork side. A preloading process manager
that uses `julewire-ractor` must also quiesce Ractors before it forks. For Puma:

```ruby
before_fork { Julewire.before_fork! }
on_worker_boot { Julewire.after_fork! }
```

Stop application work before `before_fork`; do not create Ractors or emit from
other threads until the fork finishes. If the Puma master continues logging
between worker forks, call `Julewire.after_fork!` in its parent post-fork hook.

Custom destinations still own queue, retry, delivery, and reopen behavior. The
Rails hook only gives them lifecycle opportunities.

`require_output` checks after Rails initializers that Julewire has at least one
configured destination when Julewire owns `Rails.logger`.

| Value | Behavior |
| --- | --- |
| `:warn` | Warn, but allow no-output mode. |
| `:raise` | Fail boot if no output is configured. |
| `false` | Do not check. |
