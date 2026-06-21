# Boundaries

This gem instruments Active Job.

It does not own:

- queue backend transport
- process supervisors
- queue-backend lifecycle hooks
- durable job delivery
- retry policy

Application logger calls made inside jobs remain normal Julewire records.
