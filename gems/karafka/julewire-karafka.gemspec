# frozen_string_literal: true

require_relative "lib/julewire/karafka/version"

Gem::Specification.new do |spec|
  spec.name = "julewire-karafka"
  spec.version = Julewire::Karafka::VERSION
  spec.authors = ["Alexander Grebennik"]
  spec.email = ["slbug@users.noreply.github.com", "sl.bug.sl@gmail.com"]

  spec.summary = "Karafka and WaterDrop integration for Julewire structured logging."
  spec.description =
    "Karafka monitor event capture, per-message context restoration, " \
    "and WaterDrop propagation middleware for Julewire."
  spec.homepage = "https://github.com/slbug/julewire"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.4"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/slbug/julewire/tree/main/gems/karafka"
  spec.metadata["changelog_uri"] = "https://github.com/slbug/julewire/blob/main/gems/karafka/CHANGELOG.md"

  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir.chdir(__dir__) do
    Dir[
      "CHANGELOG.md",
      "LICENSE.txt",
      "README.md",
      "docs/**/*.md",
      "julewire-karafka.gemspec",
      "lib/**/*.rb"
    ]
  end
  spec.executables = []
  spec.require_paths = ["lib"]

  spec.add_dependency "julewire-core", ">= 1.0.1"
  spec.add_dependency "karafka", ">= 2.5"
  spec.add_dependency "waterdrop", ">= 2.10"
  spec.add_dependency "zeitwerk", ">= 2.8.1"
end
