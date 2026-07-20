# frozen_string_literal: true

require_relative "ruby_source"

module Julewire
  module Quality
    module ReleaseMetadata
      class << self
        def assert!(gem_dirs:)
          failures = []
          versions = gem_dirs.to_h do |dir|
            version = version_for(dir)
            failures << "#{dir}: missing VERSION constant" unless version
            [dir, version]
          end

          gem_dirs.each { |dir| collect_failures(dir, versions.fetch(dir), failures) }
          return if failures.empty?

          raise "release metadata check failed:\n#{failures.join("\n")}"
        end

        def package_path(dir)
          version = version_for(dir)
          name = File.basename(gemspec_for(dir), ".gemspec")
          File.join("pkg", "#{name}-#{version}.gem")
        end

        private

        def version_for(dir)
          version_constant_value(parse_ruby(version_file_for(dir)).value)
        end

        def version_file_for(dir)
          File.join(dir, "lib/julewire", File.basename(dir), "version.rb")
        end

        def gemspec_for(dir)
          File.join(dir, "julewire-#{File.basename(dir)}.gemspec")
        end

        def collect_failures(dir, version, failures)
          gemspec = Gem::Specification.load(File.expand_path(gemspec_for(dir)))
          changelog = File.read(File.join(dir, "CHANGELOG.md"))

          failures << "#{dir}: gemspec must package CHANGELOG.md" unless gemspec.files.include?("CHANGELOG.md")
          if gemspec.metadata.fetch("changelog_uri", "").empty?
            failures << "#{dir}: gemspec must expose changelog_uri"
          end
          failures << "#{dir}: CHANGELOG.md must have Unreleased" unless changelog.match?(/^## Unreleased$/)
          return unless version && !changelog.match?(/^## #{Regexp.escape(version)}(?:\s+-\s+\d{4}-\d{2}-\d{2})?$/)

          failures << "#{dir}: CHANGELOG.md must have version #{version}"
        end

        def parse_ruby(path)
          RubySource.parse_file(path)
        end

        def version_constant_value(node)
          RubySource.each_node(node) do |source_node|
            return source_node.value.unescaped if version_constant_write?(source_node)
          end

          nil
        end

        def version_constant_write?(node)
          node.instance_of?(Prism::ConstantWriteNode) &&
            node.name == :VERSION &&
            node.value.instance_of?(Prism::StringNode)
        end
      end
    end
  end
end
