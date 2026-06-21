# frozen_string_literal: true

require_relative "lib/julewire/rack/version"

Gem::Specification.new do |spec|
  spec.name = "julewire-rack"
  spec.version = Julewire::Rack::VERSION
  spec.authors = ["Alexander Grebennik"]
  spec.email = ["slbug@users.noreply.github.com", "sl.bug.sl@gmail.com"]

  spec.summary = "Rack request lifecycle support for Julewire."
  spec.description = "Rack-family support primitives for Julewire request integrations."
  spec.homepage = "https://github.com/slbug/julewire"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.4"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/slbug/julewire/tree/main/gems/rack"
  spec.metadata["changelog_uri"] = "https://github.com/slbug/julewire/blob/main/gems/rack/CHANGELOG.md"

  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir.chdir(__dir__) do
    Dir[
      "CHANGELOG.md",
      "LICENSE.txt",
      "README.md",
      "julewire-rack.gemspec",
      "lib/**/*.rb"
    ]
  end
  spec.executables = []
  spec.require_paths = ["lib"]

  spec.add_dependency "julewire-core", ">= 1.0"
  spec.add_dependency "rack", ">= 3.2"
  spec.add_dependency "zeitwerk", ">= 2.8.1"
end
