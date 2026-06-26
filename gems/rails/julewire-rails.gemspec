# frozen_string_literal: true

require_relative "lib/julewire/rails/version"

Gem::Specification.new do |spec|
  spec.name = "julewire-rails"
  spec.version = Julewire::Rails::VERSION
  spec.authors = ["Alexander Grebennik"]
  spec.email = ["slbug@users.noreply.github.com", "sl.bug.sl@gmail.com"]

  spec.summary = "Rails logger and request runtime integration for Julewire."
  spec.description = "Rails 8.1+ integration that routes Rails.logger through Julewire and wraps requests in " \
                     "execution scopes."
  spec.homepage = "https://github.com/slbug/julewire"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.4"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/slbug/julewire/tree/main/gems/rails"
  spec.metadata["changelog_uri"] = "https://github.com/slbug/julewire/blob/main/gems/rails/CHANGELOG.md"

  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir.chdir(__dir__) do
    Dir[
      "CHANGELOG.md",
      "LICENSE.txt",
      "README.md",
      "docs/**/*.md",
      "julewire-rails.gemspec",
      "lib/**/*.rb"
    ]
  end
  spec.executables = []
  spec.require_paths = ["lib"]

  spec.add_dependency "actionpack", ">= 8.1"
  spec.add_dependency "actionview", ">= 8.1"
  spec.add_dependency "julewire-core", ">= 1.0.1"
  spec.add_dependency "julewire-rack", ">= 1.0.1"
  spec.add_dependency "julewire-rails_support", ">= 1.0.1"
  spec.add_dependency "logger", ">= 1.7"
  spec.add_dependency "railties", ">= 8.1"
  spec.add_dependency "zeitwerk", ">= 2.8.1"
end
