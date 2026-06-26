# frozen_string_literal: true

require_relative "lib/julewire/rails_support/version"

Gem::Specification.new do |spec|
  spec.name = "julewire-rails_support"
  spec.version = Julewire::RailsSupport::VERSION
  spec.authors = ["Alexander Grebennik"]
  spec.email = ["slbug@users.noreply.github.com", "sl.bug.sl@gmail.com"]

  spec.summary = "Shared Rails-family support helpers for Julewire integrations."
  spec.description = "Small Rails and ActiveSupport helper surface used by Julewire Rails-family integrations."
  spec.homepage = "https://github.com/slbug/julewire"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.4"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/slbug/julewire/tree/main/gems/rails_support"
  spec.metadata["changelog_uri"] = "https://github.com/slbug/julewire/blob/main/gems/rails_support/CHANGELOG.md"

  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir.chdir(__dir__) do
    Dir[
      "CHANGELOG.md",
      "LICENSE.txt",
      "README.md",
      "julewire-rails_support.gemspec",
      "lib/**/*.rb"
    ]
  end
  spec.executables = []
  spec.require_paths = ["lib"]

  spec.add_dependency "julewire-core", ">= 1.0.1"
  spec.add_dependency "zeitwerk", ">= 2.8.1"
end
