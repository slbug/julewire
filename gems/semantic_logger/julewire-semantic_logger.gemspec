# frozen_string_literal: true

require_relative "lib/julewire/semantic_logger/version"

Gem::Specification.new do |spec|
  spec.name = "julewire-semantic_logger"
  spec.version = Julewire::SemanticLogger::VERSION
  spec.authors = ["Alexander Grebennik"]
  spec.email = ["slbug@users.noreply.github.com", "sl.bug.sl@gmail.com"]

  spec.summary = "Semantic Logger transport adapter for Julewire."
  spec.description = "Semantic Logger transport adapter for Julewire destination output."
  spec.homepage = "https://github.com/slbug/julewire"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.4"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/slbug/julewire/tree/main/gems/semantic_logger"
  spec.metadata["changelog_uri"] = "https://github.com/slbug/julewire/blob/main/gems/semantic_logger/CHANGELOG.md"

  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir.chdir(__dir__) do
    Dir[
      "CHANGELOG.md",
      "LICENSE.txt",
      "README.md",
      "docs/**/*.md",
      "julewire-semantic_logger.gemspec",
      "lib/**/*.rb"
    ]
  end
  spec.executables = []
  spec.require_paths = ["lib"]

  spec.add_dependency "julewire-core", ">= 1.0"
  spec.add_dependency "logger", ">= 1.7"
  spec.add_dependency "semantic_logger", ">= 4.18"
  spec.add_dependency "zeitwerk", ">= 2.8.1"
end
