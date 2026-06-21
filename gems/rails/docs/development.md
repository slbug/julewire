# Development

Run the normal gem checks:

```sh
bundle exec rake
```

Run the Rails appraisal suite:

```sh
bundle exec rake appraisal:test
BUNDLE_GEMFILE=gemfiles/rails_8_1.gemfile bundle exec rake test
BUNDLE_GEMFILE=gemfiles/rails_head.gemfile bundle exec rake test
```

The real-stack tests live under `test/dummy` and exercise a booted Rails app,
default log-subscriber silencing, Rails structured events, logger calls, request
summaries, and body-capture media gates. Add future Rails versions by adding
another gemfile under `gemfiles/` and adding it to `RAILS_APPRAISAL_TARGETS`.
`rails_head` tracks the Rails repository's default branch.
