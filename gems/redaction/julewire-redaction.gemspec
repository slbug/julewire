# frozen_string_literal: true

require_relative "lib/julewire/redaction/version"

Gem::Specification.new do |spec|
  spec.name = "julewire-redaction"
  spec.version = Julewire::Redaction::VERSION
  spec.authors = ["Alexander Grebennik"]
  spec.email = ["slbug@users.noreply.github.com", "sl.bug.sl@gmail.com"]

  spec.summary = "Structured redaction processor for Julewire."
  spec.description = "Structured key/value and string redaction processor for Julewire records."
  spec.homepage = "https://github.com/slbug/julewire"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.4"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/slbug/julewire/tree/main/gems/redaction"
  spec.metadata["changelog_uri"] = "https://github.com/slbug/julewire/blob/main/gems/redaction/CHANGELOG.md"

  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir.chdir(__dir__) do
    Dir[
      "CHANGELOG.md",
      "LICENSE.txt",
      "README.md",
      "docs/**/*.md",
      "julewire-redaction.gemspec",
      "lib/**/*.rb"
    ]
  end
  spec.executables = []
  spec.require_paths = ["lib"]

  spec.add_dependency "julewire-core", ">= 1.0.1"
  spec.add_dependency "zeitwerk", ">= 2.8.1"
end
