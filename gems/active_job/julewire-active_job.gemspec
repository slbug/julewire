# frozen_string_literal: true

require_relative "lib/julewire/active_job/version"

Gem::Specification.new do |spec|
  spec.name = "julewire-active_job"
  spec.version = Julewire::ActiveJob::VERSION
  spec.authors = ["Alexander Grebennik"]
  spec.email = ["slbug@users.noreply.github.com", "sl.bug.sl@gmail.com"]

  spec.summary = "Active Job integration for Julewire structured logging."
  spec.description =
    "Execution-scoped Active Job instrumentation, structured event capture, " \
    "and propagation carrier support for Julewire."
  spec.homepage = "https://github.com/slbug/julewire"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.4"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/slbug/julewire/tree/main/gems/active_job"
  spec.metadata["changelog_uri"] = "https://github.com/slbug/julewire/blob/main/gems/active_job/CHANGELOG.md"

  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir.chdir(__dir__) do
    Dir[
      "CHANGELOG.md",
      "LICENSE.txt",
      "README.md",
      "docs/**/*.md",
      "julewire-active_job.gemspec",
      "lib/**/*.rb"
    ]
  end
  spec.executables = []
  spec.require_paths = ["lib"]

  spec.add_dependency "activejob", ">= 8.1"
  spec.add_dependency "julewire-core", ">= 1.0.1"
  spec.add_dependency "julewire-rails_support", ">= 1.0.1"
  spec.add_dependency "zeitwerk", ">= 2.8.1"
end
