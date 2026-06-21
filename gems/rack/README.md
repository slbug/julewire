# Julewire Rack

Rack-family request lifecycle support for Julewire integrations.

This gem is deliberately framework-neutral. It is the place for Rack request
primitives that can be shared by Rails, Grape, and other Rack-based adapters.
Rails and ActiveSupport EventReporter helpers stay in `julewire-rails_support`.

It owns capture helpers for request bodies, response bodies, headers, content
types, and JSON-ish payload extraction. It does not install middleware by
itself; framework gems decide when those primitives belong in a request
pipeline.

Applications normally install a framework adapter, not this support gem. Use it
directly when writing a Rack-shaped Julewire integration.
