# frozen_string_literal: true

require_relative "lib/julewire/core/version"

Gem::Specification.new do |spec|
  spec.name = "julewire-core"
  spec.version = Julewire::Core::VERSION
  spec.authors = ["Alexander Grebennik"]
  spec.email = ["slbug@users.noreply.github.com", "sl.bug.sl@gmail.com"]

  spec.summary = "Execution-scoped structured logging core for Ruby applications."
  spec.description =
    "Provider-neutral records, execution context, processors, destinations, " \
    "and formatters for Julewire."
  spec.homepage = "https://github.com/slbug/julewire"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.4"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/slbug/julewire/tree/main/gems/core"
  spec.metadata["changelog_uri"] = "https://github.com/slbug/julewire/blob/main/gems/core/CHANGELOG.md"

  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir.chdir(__dir__) do
    Dir[
      "CHANGELOG.md",
      "LICENSE.txt",
      "README.md",
      "docs/**/*.md",
      "exe/*",
      "julewire-core.gemspec",
      "lib/**/*.rb"
    ]
  end
  spec.bindir = "exe"
  spec.executables = ["julewire"]
  spec.require_paths = ["lib"]

  spec.add_dependency "concurrent-ruby", ">= 1.3"
  spec.add_dependency "zeitwerk", ">= 2.8.1"
end
