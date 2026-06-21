# Julewire Rails Support

Shared Rails-family support helpers for Julewire integrations. This gem keeps
Rails and ActiveSupport constants out of `julewire-core`.

It owns the small Rails edge pieces that are useful to more than one adapter:
EventReporter subscription helpers, log-subscriber silencing, and
framework-version probes. `julewire-rails` and `julewire-active_job` use it so
core stays Ruby-only.

Applications should not usually depend on this gem directly. Reach for
`julewire-rails` or `julewire-active_job`; use this only when building another
Rails-family integration.
