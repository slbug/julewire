# frozen_string_literal: true

require "test_helper"
require File.expand_path("../../../../support/mutant/targets", __dir__)
require File.expand_path("../../../../support/quality/boundaries", __dir__)
require File.expand_path("../../../../support/quality/flay", __dir__)
require File.expand_path("../../../../support/quality/release_metadata", __dir__)

module Julewire
  class TestQualityBoundaries < Minitest::Test
    cover Julewire::Quality::Boundaries
    cover Julewire::Quality::RubySource

    def test_core_neutrality_flags_framework_constant
      in_temporary_repo do
        write_temporary_repo_file("gems/core/lib/julewire/core/probe.rb", <<~RUBY)
          module Julewire
            module Core
              ActiveSupport::TaggedLogging
              Forbidden
            end
          end
        RUBY

        error = assert_raises(RuntimeError) do
          Julewire::Quality::Boundaries.assert_core_neutrality(
            allowed_constants: [],
            allowed_constants_by_path: {},
            core_public_alias_prefixes: []
          )
        end

        assert_includes error.message, "gems/core/lib/julewire/core/probe.rb:3:ActiveSupport::TaggedLogging"
        assert_includes error.message, "gems/core/lib/julewire/core/probe.rb:4:Forbidden"
      end
    end

    def test_core_neutrality_rejects_unallowed_dynamic_constant_skip
      in_temporary_repo do
        write_temporary_repo_file("gems/core/lib/julewire/core/probe.rb", <<~RUBY)
          module Julewire
            module Core
              serializer = String
              serializer::MAX_DEPTH_VALUE
            end
          end
        RUBY

        error = nil
        _stdout, stderr = capture_io do
          error = assert_raises(RuntimeError) do
            Julewire::Quality::Boundaries.assert_core_neutrality(
              allowed_constants: ["String"],
              allowed_constants_by_path: {},
              core_public_alias_prefixes: []
            )
          end
        end

        assert_includes stderr, "warning: skipping dynamic constant path"
        assert_includes error.message, "unexpected dynamic constant path skips"
        assert_includes error.message, "gems/core/lib/julewire/core/probe.rb:4"
      end
    end

    def test_integration_boundaries_flags_unallowed_sibling_reference
      in_temporary_repo do
        write_temporary_repo_file("gems/rails/lib/julewire/rails/probe.rb", <<~RUBY)
          module Julewire
            module Rails
              Julewire::GCP::Formatter
            end
          end
        RUBY

        error = assert_raises(RuntimeError) do
          assert_integration_boundaries
        end

        assert_includes error.message, "gems/rails/lib/julewire/rails/probe.rb:3:Julewire::GCP::Formatter"
      end
    end

    def test_integration_boundaries_allows_bareword_reference_to_own_namespace
      in_temporary_repo do
        write_temporary_repo_file("gems/rails/lib/julewire/rails/logger.rb", <<~RUBY)
          module Julewire
            module Rails
              module Logger
              end
            end
          end
        RUBY
        write_temporary_repo_file("gems/rails/lib/julewire/rails/probe.rb", <<~RUBY)
          module Julewire
            module Rails
              Rails::Logger
            end
          end
        RUBY

        assert_nil assert_integration_boundaries
      end
    end

    def test_integration_boundaries_rejects_bareword_sibling_reference
      in_temporary_repo do
        write_temporary_repo_file("gems/rails/lib/julewire/rails/probe.rb", <<~RUBY)
          module Julewire
            module Rails
              GCP::Formatter
            end
          end
        RUBY

        error = assert_raises(RuntimeError) do
          Julewire::Quality::Boundaries.assert_integration_boundaries(
            integration_dirs: ["gems/rails"],
            integration_namespaces: {
              "gems/rails" => "Julewire::Rails",
              "gems/gcp" => "Julewire::GCP"
            },
            integration_allowed_references: { "gems/rails" => [] },
            core_public_alias_prefixes: [],
            core_spi_allowed_prefixes: [],
            core_bridge_allowed_prefixes: []
          )
        end

        assert_includes error.message, "gems/rails/lib/julewire/rails/probe.rb:3:Julewire::GCP::Formatter"
      end
    end

    def test_integration_boundaries_accepts_own_namespace_declared_sibling_public_alias_and_core_spi
      in_temporary_repo do
        write_temporary_repo_file("gems/rails/lib/julewire/rails/probe.rb", <<~RUBY)
          Julewire::Rails::Request
          Rails::Request
          Julewire::RailsSupport::EventReporter
          RailsSupport::EventReporter
          Julewire::Error
          Error
          Julewire::Core
          Core
          Julewire::Core::Integration::Protocol
          ::Julewire::Core::Integration::Protocol
          Core::Integration::Protocol
          ::ActiveSupport::TaggedLogging
        RUBY

        assert_nil Julewire::Quality::Boundaries.assert_integration_boundaries(
          integration_dirs: ["gems/rails"],
          integration_namespaces: {
            "gems/rails" => "Julewire::Rails",
            "gems/rails_support" => "Julewire::RailsSupport"
          },
          integration_allowed_references: { "gems/rails" => ["Julewire::RailsSupport"] },
          core_public_alias_prefixes: ["Julewire::Error"],
          core_spi_allowed_prefixes: ["Core::Integration"],
          core_bridge_allowed_prefixes: []
        )
      end
    end

    def test_integration_boundaries_rejects_private_core_similar_prefixes_and_absolute_siblings
      in_temporary_repo do
        path = "gems/rails/lib/julewire/rails/probe.rb"
        write_private_core_boundary_fixture(path)

        error = assert_raises(RuntimeError) do
          Julewire::Quality::Boundaries.assert_integration_boundaries(
            **private_core_boundary_arguments
          )
        end

        assert_equal private_core_boundary_error(path), error.message
      end
    end

    def test_integration_boundaries_rejects_every_dynamic_constant_path_skip
      in_temporary_repo do
        path = "gems/rails/lib/julewire/rails/probe.rb"
        write_temporary_repo_file(path, <<~RUBY)
          first = String
          first::VALUE
          second = String
          second::VALUE
        RUBY

        error = nil
        _stdout, stderr = capture_io do
          error = assert_raises(RuntimeError) do
            assert_integration_boundaries
          end
        end

        assert_equal(
          [
            "unexpected dynamic constant path skips:",
            "warning: skipping dynamic constant path in #{path}:2",
            "warning: skipping dynamic constant path in #{path}:4"
          ].join("\n"),
          error.message
        )
        assert_equal 2, stderr.scan("warning: skipping dynamic constant path").size
      end
    end

    def test_bridge_spi_is_available_to_ractor
      in_temporary_repo do
        write_temporary_repo_file("gems/ractor/lib/julewire/ractor/probe.rb", "Core::RactorBridge::Message\n")

        assert_nil Julewire::Quality::Boundaries.assert_integration_boundaries(
          integration_dirs: ["gems/ractor"],
          **bridge_boundary_arguments
        )
      end
    end

    def test_ractor_cannot_use_private_core_implementation
      in_temporary_repo do
        write_temporary_repo_file(
          "gems/ractor/lib/julewire/ractor/private_probe.rb",
          "Core::Private::Value\n"
        )
        ractor_error = assert_raises(RuntimeError) do
          Julewire::Quality::Boundaries.assert_integration_boundaries(
            integration_dirs: ["gems/ractor"],
            **bridge_boundary_arguments
          )
        end

        assert_includes ractor_error.message, "gems/ractor/lib/julewire/ractor/private_probe.rb:1:Core::Private::Value"
      end
    end

    def test_bridge_spi_is_unavailable_to_other_integration_gems
      in_temporary_repo do
        write_temporary_repo_file("gems/rails/lib/julewire/rails/probe.rb", "Core::RactorBridge::Message\n")

        error = assert_raises(RuntimeError) do
          Julewire::Quality::Boundaries.assert_integration_boundaries(
            integration_dirs: ["gems/rails"],
            **bridge_boundary_arguments
          )
        end

        assert_includes error.message, "gems/rails/lib/julewire/rails/probe.rb:1:Core::RactorBridge::Message"
      end
    end

    def test_core_neutrality_accepts_core_local_declared_and_public_alias_constants
      in_temporary_repo do
        path = "gems/core/lib/julewire/core/probe.rb"
        write_allowed_core_neutrality_fixture(path)

        assert_nil Julewire::Quality::Boundaries.assert_core_neutrality(
          allowed_constants: ["SharedDependency"],
          allowed_constants_by_path: { path => ["PathDependency"] },
          core_public_alias_prefixes: ["Julewire::Error"]
        )
      end
    end

    def test_core_neutrality_rejects_similar_core_prefix_and_sibling_gem_constants
      in_temporary_repo do
        path = "gems/core/lib/julewire/core/probe.rb"
        write_temporary_repo_file("gems/core/lib/julewire.rb", "module Julewire\nend\n")
        write_temporary_repo_file(path, <<~RUBY)
          Julewire::CoreBad::Runtime
          Julewire::Rails::Request
          Julewire::Errorish::Value
        RUBY

        error = assert_raises(RuntimeError) do
          Julewire::Quality::Boundaries.assert_core_neutrality(
            allowed_constants: [],
            allowed_constants_by_path: {},
            core_public_alias_prefixes: ["Julewire::Error"]
          )
        end

        assert_equal(
          [
            "core must use only core, stdlib, and declared dependency constants:",
            "#{path}:1:Julewire::CoreBad::Runtime",
            "#{path}:2:Julewire::Rails::Request",
            "#{path}:3:Julewire::Errorish::Value"
          ].join("\n"),
          error.message
        )
      end
    end

    def test_safe_method_names_reject_object_and_kernel_collisions
      in_temporary_repo do
        first_path = "gems/core/lib/julewire/core/alpha.rb"
        second_path = "gems/core/lib/julewire/core/zebra.rb"
        write_temporary_repo_file(first_path, unsafe_fork_source)
        write_temporary_repo_file(second_path, unsafe_system_source)

        error = assert_raises(RuntimeError) do
          Julewire::Quality::Boundaries.assert_safe_method_names(
            paths: [second_path, first_path],
            allowed_method_names: []
          )
        end

        assert_equal(
          [
            "production methods must not collide with Object or Kernel:",
            "#{first_path}:2:fork",
            "#{second_path}:2:system"
          ].join("\n"),
          error.message
        )
      end
    end

    def test_safe_method_names_accepts_explicit_protocol_allowlist
      in_temporary_repo do
        path = "gems/core/lib/julewire/core/probe.rb"
        write_temporary_repo_file(path, <<~RUBY)
          class Julewire::Core::Probe
            def initialize
            end

            def inspect
            end
          end
        RUBY

        assert_nil Julewire::Quality::Boundaries.assert_safe_method_names(
          paths: [path],
          allowed_method_names: %i[initialize inspect]
        )
      end
    end

    def test_safe_method_names_ignores_methods_added_to_object_after_guard_load
      path = "gems/core/lib/julewire/core/probe.rb"
      Object.class_eval do
        private def quality_guard_late_probe; end
      end

      in_temporary_repo do
        write_temporary_repo_file(path, <<~RUBY)
          class Julewire::Core::Probe
            def quality_guard_late_probe
            end
          end
        RUBY

        assert_nil Julewire::Quality::Boundaries.assert_safe_method_names(
          paths: [path],
          allowed_method_names: []
        )
      end
    ensure
      Object.__send__(:remove_method, :quality_guard_late_probe)
    end

    private

    def bridge_boundary_arguments
      {
        integration_namespaces: {
          "gems/ractor" => "Julewire::Ractor",
          "gems/rails" => "Julewire::Rails"
        },
        integration_allowed_references: {},
        core_public_alias_prefixes: [],
        core_spi_allowed_prefixes: [],
        core_bridge_allowed_prefixes: ["Core::RactorBridge"]
      }
    end

    def private_core_boundary_arguments
      {
        integration_dirs: ["gems/rails"],
        integration_namespaces: {
          "gems/rails" => "Julewire::Rails",
          "gems/gcp" => "Julewire::GCP"
        },
        integration_allowed_references: {},
        core_public_alias_prefixes: [],
        core_spi_allowed_prefixes: ["Core::Integration"],
        core_bridge_allowed_prefixes: []
      }
    end

    def private_core_boundary_error(path)
      [
        "integration gems must use documented Core SPI:",
        "#{path}:1:Core::Private::Value",
        "#{path}:2:Core::Private::Value",
        "#{path}:3:Core::Private::Value",
        "#{path}:4:Julewire::RailsExtra::Request",
        "#{path}:5:Julewire::GCP::Formatter"
      ].join("\n")
    end

    def write_allowed_core_neutrality_fixture(path)
      write_temporary_repo_file("gems/core/lib/julewire/core/helper.rb", <<~RUBY)
        module Helper
        end
        class ClassHelper
        end
        CONSTANT_HELPER = true
        Namespace::PATH_HELPER = true
      RUBY
      write_temporary_repo_file(path, <<~RUBY)
        Julewire
        Julewire::Core
        Julewire::Core::Runtime
        ::Julewire::Core::Runtime
        Julewire::Error
        ::Julewire::Error
        Julewire::Error::Nested
        Core
        Core::Runtime
        Helper
        ClassHelper
        CONSTANT_HELPER
        Namespace::PATH_HELPER
        PathDependency::Value
        SharedDependency::Value
      RUBY
    end

    def write_private_core_boundary_fixture(path)
      write_temporary_repo_file(path, <<~RUBY)
        Core::Private::Value
        Julewire::Core::Private::Value
        ::Julewire::Core::Private::Value
        Julewire::RailsExtra::Request
        ::Julewire::GCP::Formatter
      RUBY
    end

    def unsafe_fork_source
      <<~RUBY
        class Julewire::Core::Probe
          def fork
          end
        end
      RUBY
    end

    def unsafe_system_source
      <<~RUBY
        class Julewire::Core::OtherProbe
          def system
          end
        end
      RUBY
    end

    def assert_integration_boundaries
      Julewire::Quality::Boundaries.assert_integration_boundaries(
        integration_dirs: ["gems/rails"],
        integration_namespaces: { "gems/rails" => "Julewire::Rails" },
        integration_allowed_references: {},
        core_public_alias_prefixes: [],
        core_spi_allowed_prefixes: [],
        core_bridge_allowed_prefixes: []
      )
    end
  end

  class TestQualityReleaseMetadata < Minitest::Test
    cover Julewire::Quality::ReleaseMetadata

    def test_release_metadata_reports_missing_changelog_version
      in_temporary_repo do
        build_gem_fixture(changelog: <<~MARKDOWN)
          ## Unreleased

          ## 0.9.0 - 2026-01-01
        MARKDOWN

        error = assert_raises(RuntimeError) do
          Julewire::Quality::ReleaseMetadata.assert!(gem_dirs: ["gems/probe"])
        end

        assert_includes error.message, "gems/probe: CHANGELOG.md must have version 1.2.3"
      end
    end

    def test_release_metadata_treats_version_text_as_literal_regex_input
      in_temporary_repo do
        build_gem_fixture(changelog: <<~MARKDOWN)
          # Changes

          ## Unreleased

          ## 1x2y3 - 2026-07-08
        MARKDOWN

        error = assert_raises(RuntimeError) do
          Julewire::Quality::ReleaseMetadata.assert!(gem_dirs: ["gems/probe"])
        end

        assert_includes error.message, "gems/probe: CHANGELOG.md must have version 1.2.3"
      end
    end

    def test_release_metadata_package_path_uses_gemspec_name_and_version
      in_temporary_repo do
        build_gem_fixture

        assert_equal(
          "pkg/julewire-probe-1.2.3.gem",
          Julewire::Quality::ReleaseMetadata.package_path("gems/probe")
        )
      end
    end

    def test_release_metadata_accepts_complete_metadata
      in_temporary_repo do
        build_gem_fixture

        assert_nil Julewire::Quality::ReleaseMetadata.assert!(gem_dirs: ["gems/probe"])
      end
    end

    def test_release_metadata_reports_all_package_and_changelog_failures
      in_temporary_repo do
        build_gem_fixture(
          changelog: "# Changes\n",
          files: [],
          metadata: {}
        )

        error = assert_raises(RuntimeError) do
          Julewire::Quality::ReleaseMetadata.assert!(gem_dirs: ["gems/probe"])
        end

        assert_equal(
          [
            "release metadata check failed:",
            "gems/probe: gemspec must package CHANGELOG.md",
            "gems/probe: gemspec must expose changelog_uri",
            "gems/probe: CHANGELOG.md must have Unreleased",
            "gems/probe: CHANGELOG.md must have version 1.2.3"
          ].join("\n"),
          error.message
        )
      end
    end

    def test_release_metadata_reports_missing_or_misnamed_version_constants
      in_temporary_repo do
        build_gem_fixture(version_source: "module Julewire::Probe\n  RELEASE = \"1.2.3\"\nend\n")

        error = assert_raises(RuntimeError) do
          Julewire::Quality::ReleaseMetadata.assert!(gem_dirs: ["gems/probe"])
        end

        assert_includes error.message, "gems/probe: missing VERSION constant"
      end
    end

    def test_release_metadata_requires_a_string_version_constant
      in_temporary_repo do
        build_gem_fixture(version_source: "module Julewire::Probe\n  VERSION = 123\nend\n")

        error = assert_raises(RuntimeError) do
          Julewire::Quality::ReleaseMetadata.assert!(gem_dirs: ["gems/probe"])
        end

        assert_includes error.message, "gems/probe: missing VERSION constant"
      end
    end

    def test_release_metadata_rejects_an_empty_changelog_uri
      in_temporary_repo do
        build_gem_fixture(metadata: { "changelog_uri" => "" })

        error = assert_raises(RuntimeError) do
          Julewire::Quality::ReleaseMetadata.assert!(gem_dirs: ["gems/probe"])
        end

        assert_includes error.message, "gems/probe: gemspec must expose changelog_uri"
      end
    end

    private

    def build_gem_fixture(changelog: nil, files: ["CHANGELOG.md"], metadata: nil, version_source: nil)
      write_temporary_repo_file("gems/probe/lib/julewire/probe/version.rb", version_source || <<~RUBY)
        module Julewire
          module Probe
            VERSION = "1.2.3"
          end
        end
      RUBY
      write_temporary_repo_file("gems/probe/julewire-probe.gemspec", <<~RUBY)
        Gem::Specification.new do |spec|
          spec.name = "julewire-probe"
          spec.version = "1.2.3"
          spec.files = #{files.inspect}
          spec.metadata = #{(metadata || { "changelog_uri" => "https://example.invalid/changelog" }).inspect}
        end
      RUBY
      write_temporary_repo_file("gems/probe/CHANGELOG.md", changelog || <<~MARKDOWN)
        # Changes

        ## Unreleased

        ## 1.2.3 - 2026-07-08
      MARKDOWN
    end
  end

  class TestMutantTargets < Minitest::Test
    cover Julewire::Mutant::Targets
    cover Julewire::Mutant::Targets::Discovery
    cover Julewire::Mutant::Targets::MethodShapeScan
    cover Julewire::Quality::RubySource

    def test_mutant_target_discovery_covers_root_constants_and_public_facade_methods
      in_temporary_repo do
        write_temporary_repo_file("gems/probe/lib/julewire.rb", <<~RUBY)
          module Julewire
            module Facade
              def exposed
              end

              private

              def hidden
              end
            end

            Record = Data.define(:value)

            extend Facade

            def self.direct
            end
          end
        RUBY

        assert_equal(
          [
            "Julewire.direct",
            "Julewire.exposed",
            "Julewire::Facade*",
            "Julewire::Probe*",
            "Julewire::Record*"
          ],
          Julewire::Mutant::Targets.subjects_for(dir: "gems/probe", namespace: "Julewire::Probe")
        )
      end
    end

    def test_mutant_target_discovery_handles_singleton_classes_and_constant_paths
      in_temporary_repo do
        write_temporary_repo_file("gems/probe/lib/julewire/probe.rb", <<~RUBY)
          module Julewire
            Config::DEFAULT = 1

            class << self
              def configured?
              end
            end
          end
        RUBY

        assert_equal(
          ["Julewire.configured?", "Julewire::Config*", "Julewire::Probe*"],
          Julewire::Mutant::Targets.subjects_for(dir: "gems/probe", namespace: "Julewire::Probe")
        )
      end
    end

    def test_mutant_target_discovery_collects_public_methods_from_root_extensions
      in_temporary_repo do
        write_temporary_repo_file("gems/probe/lib/julewire/probe.rb", root_extension_visibility_source)
        write_temporary_repo_file("gems/probe/lib/julewire/reopen.rb", reopened_root_extension_source)

        assert_equal(
          [
            "Julewire.after_argument_visibility",
            "Julewire.after_non_visibility_call",
            "Julewire.first",
            "Julewire.second",
            "Julewire::Facade*",
            "Julewire::Probe*"
          ],
          discovered_probe_subjects
        )
      end
    end

    def test_mutant_target_discovery_collects_only_root_constants
      in_temporary_repo do
        write_temporary_repo_file("gems/probe/lib/julewire/probe.rb", root_constant_source)

        assert_equal(
          [
            "Julewire::Absolute*",
            "Julewire::Alias*",
            "Julewire::Alpha*",
            "Julewire::Config*",
            "Julewire::Probe*",
            "Julewire::Rooted*",
            "Julewire::Zebra*"
          ],
          discovered_probe_subjects
        )
      end
    end

    def test_mutant_target_discovery_collects_only_root_singleton_methods
      in_temporary_repo do
        write_temporary_repo_file("gems/probe/lib/julewire/probe.rb", root_singleton_method_source)

        assert_equal(
          [
            "Julewire.direct",
            "Julewire.named",
            "Julewire.singleton",
            "Julewire::Nested*",
            "Julewire::Probe*"
          ],
          discovered_probe_subjects
        )
      end
    end

    def test_mutant_target_discovery_extends_only_literal_modules_at_the_root
      in_temporary_repo do
        write_temporary_repo_file("gems/probe/lib/julewire/probe.rb", root_extension_selection_source)

        assert_equal(
          [
            "Julewire.root_method",
            "Julewire::IncludedOnly*",
            "Julewire::Nested*",
            "Julewire::NestedOnly*",
            "Julewire::Probe*",
            "Julewire::ReceivedOnly*",
            "Julewire::RootFacade*"
          ],
          discovered_probe_subjects
        )
      end
    end

    def test_mutant_runtime_subject_check_reports_unloaded_production_methods
      requirements = {
        "gems/loaded" => ["Julewire::Loaded.call"],
        "gems/optional" => ["Julewire::Optional.install!", "Julewire::Optional.start"]
      }
      subject_lists = {
        "gems/loaded" => ["Julewire::Loaded.call"],
        "gems/optional" => []
      }

      error = assert_raises(RuntimeError) do
        Julewire::Mutant::Targets.assert_runtime_subjects!(requirements: requirements, subject_lists: subject_lists)
      end

      assert_equal(
        "production methods missing from Mutant runtime inventory:\n" \
        "gems/optional: Julewire::Optional.install!\n" \
        "gems/optional: Julewire::Optional.start",
        error.message
      )
    end

    def test_mutant_runtime_subject_check_accepts_loaded_production_methods
      requirements = { "gems/loaded" => ["Julewire::Loaded.call"] }
      subject_lists = { "gems/loaded" => ["Julewire::Loaded.call"] }

      assert_nil Julewire::Mutant::Targets.assert_runtime_subjects!(
        requirements: requirements,
        subject_lists: subject_lists
      )
    end

    def test_mutant_method_shape_check_rejects_methods_on_anonymous_value_and_module_owners
      in_temporary_repo do
        path = "gems/probe/lib/julewire/probe.rb"
        write_temporary_repo_file(path, anonymous_method_shape_source)

        error = assert_raises(RuntimeError) do
          Julewire::Mutant::Targets.assert_visible_method_shapes!(gem_dirs: ["gems/probe"])
        end

        assert_equal(
          [
            "production method bodies must be visible to Mutant:",
            "#{path}:3:rendered is defined inside Data.define",
            "#{path}:7:call is defined inside Module.new",
            "#{path}:11:perform is defined inside Class.new",
            "#{path}:15:combined is defined inside Struct.new"
          ].join("\n"),
          error.message
        )
      end
    end

    def test_mutant_method_shape_check_ignores_unrecognized_factory_methods_and_nested_named_factories
      in_temporary_repo do
        path = "gems/probe/lib/julewire/probe.rb"
        write_temporary_repo_file(path, <<~RUBY)
          module Julewire::Probe
            Plain = Class.new

            Value = Data.new do
              def rendered = true
            end

            OtherValue = Factory.define do
              def rendered = true
            end

            def self.build(owner)
              owner.define_method(:value) { true }
            end
          end
        RUBY

        assert_nil Julewire::Mutant::Targets.assert_visible_method_shapes!(gem_dirs: ["gems/probe"])
      end
    end

    def test_mutant_method_shape_check_attributes_argument_and_owner_blocks_separately
      in_temporary_repo do
        path = "gems/probe/lib/julewire/probe.rb"
        write_temporary_repo_file(path, <<~RUBY)
          module Julewire::Probe
            Value = Data.define(
              Class.new do
                def helper = true
              end
            ) do
              def rendered = true
            end
          end
        RUBY

        error = assert_raises(RuntimeError) do
          Julewire::Mutant::Targets.assert_visible_method_shapes!(gem_dirs: ["gems/probe"])
        end

        assert_equal(
          [
            "production method bodies must be visible to Mutant:",
            "#{path}:7:rendered is defined inside Data.define",
            "#{path}:4:helper is defined inside Class.new"
          ].join("\n"),
          error.message
        )
      end
    end

    def test_mutant_method_shape_check_attributes_nested_methods_to_their_real_owner
      in_temporary_repo do
        path = "gems/probe/lib/julewire/probe.rb"
        write_temporary_repo_file(path, nested_anonymous_method_shape_source)

        error = assert_raises(RuntimeError) do
          Julewire::Mutant::Targets.assert_visible_method_shapes!(gem_dirs: ["gems/probe"])
        end

        assert_equal(
          "production method bodies must be visible to Mutant:\n" \
          "#{path}:12:hidden is defined inside Class.new",
          error.message
        )
      end
    end

    def test_mutant_method_shape_check_rejects_unexpected_class_body_define_method
      in_temporary_repo do
        path = "gems/probe/lib/julewire/probe.rb"
        write_temporary_repo_file(path, <<~RUBY)
          class Julewire::Probe
            define_method(:value) { true }
            define_method(:other) { false }
          end
        RUBY

        error = assert_raises(RuntimeError) do
          Julewire::Mutant::Targets.assert_visible_method_shapes!(gem_dirs: ["gems/probe"])
        end

        assert_equal(
          "production method bodies must be visible to Mutant:\n" \
          "#{path}: expected 0 class-body define_method call(s), found 2 at 2, 3",
          error.message
        )
      end
    end

    def test_mutant_method_shape_check_rejects_stale_generated_accessor_allowlist
      in_temporary_repo do
        path = "gems/probe/lib/julewire/missing.rb"
        write_temporary_repo_file("gems/probe/lib/julewire/probe.rb", "module Julewire::Probe\nend\n")

        error = assert_raises(RuntimeError) do
          Julewire::Mutant::Targets.assert_visible_method_shapes!(
            gem_dirs: ["gems/probe"],
            allowed_class_body_define_method_counts: { path => 1 }
          )
        end

        assert_equal(
          "production method bodies must be visible to Mutant:\n" \
          "#{path}: expected 1 class-body define_method call(s), found 0 at ",
          error.message
        )
      end
    end

    def test_mutant_method_shape_check_accepts_declared_generated_accessors_and_named_factories
      in_temporary_repo do
        path = "gems/probe/lib/julewire/probe.rb"
        write_temporary_repo_file(path, <<~RUBY)
          class Julewire::Probe
            include Enumerable
            define_method(:value) { @value }

            def self.install(name)
              define_method(name) { true }
            end
          end
        RUBY

        assert_nil Julewire::Mutant::Targets.assert_visible_method_shapes!(
          gem_dirs: ["gems/probe"],
          allowed_class_body_define_method_counts: { path => 1 }
        )
      end
    end

    def test_mutant_target_discovery_includes_repository_subjects_explicitly
      in_temporary_repo do
        write_temporary_repo_file("gems/probe/lib/julewire/probe.rb", "module Julewire::Probe\nend\n")

        assert_equal(
          ["Julewire::Mutant::Targets*", "Julewire::Probe*", "Julewire::Quality*"],
          Julewire::Mutant::Targets.subjects_for(
            dir: "gems/probe",
            namespace: "Julewire::Probe",
            additional_subjects: %w[Julewire::Quality* Julewire::Mutant::Targets*]
          )
        )
      end
    end

    def test_mutant_target_update_writes_discovered_subjects_and_preserves_configuration
      in_temporary_repo do
        build_mutant_target_fixture

        assert_nil Julewire::Mutant::Targets.update!(
          gem_dirs: ["gems/probe"],
          namespaces: { "gems/probe" => "Julewire::Probe" },
          additional_subjects: { "gems/probe" => ["Julewire::Quality*"] }
        )

        config = YAML.safe_load_file("gems/probe/.mutant.yml", aliases: false)

        assert_equal "opensource", config.fetch("usage")
        assert_equal ["Julewire::Probe*", "Julewire::Quality*"], config.dig("matcher", "subjects")
      end
    end

    def test_mutant_target_update_defaults_to_no_extra_subjects_and_creates_matcher_configuration
      in_temporary_repo do
        write_temporary_repo_file("gems/probe/lib/julewire/probe.rb", "module Julewire::Probe\nend\n")
        write_temporary_repo_file("gems/probe/.mutant.yml", YAML.dump("usage" => "opensource"))
        arguments = {
          gem_dirs: ["gems/probe"],
          namespaces: { "gems/probe" => "Julewire::Probe" }
        }

        assert_nil Julewire::Mutant::Targets.update!(**arguments)
        assert_nil Julewire::Mutant::Targets.assert_fresh!(**arguments)

        config = YAML.safe_load_file("gems/probe/.mutant.yml", aliases: false)

        assert_equal ["Julewire::Probe*"], config.dig("matcher", "subjects")
      end
    end

    def test_mutant_target_freshness_accepts_generated_config_and_reports_stale_config
      in_temporary_repo do
        build_mutant_target_fixture
        arguments = {
          gem_dirs: ["gems/probe"],
          namespaces: { "gems/probe" => "Julewire::Probe" },
          additional_subjects: { "gems/probe" => ["Julewire::Quality*"] }
        }
        Julewire::Mutant::Targets.update!(**arguments)

        assert_nil Julewire::Mutant::Targets.assert_fresh!(**arguments)

        config = YAML.safe_load_file("gems/probe/.mutant.yml", aliases: false)
        config.fetch("matcher").fetch("subjects") << "Julewire::Stale*"
        File.write("gems/probe/.mutant.yml", YAML.dump(config))

        error = assert_raises(RuntimeError) { Julewire::Mutant::Targets.assert_fresh!(**arguments) }

        assert_equal(
          "stale mutant target configs; run `rake mutant:targets`:\ngems/probe/.mutant.yml",
          error.message
        )
      end
    end

    def test_mutant_target_freshness_reports_each_stale_gem_on_its_own_line
      in_temporary_repo do
        build_mutant_target_fixture(dir: "gems/alpha")
        build_mutant_target_fixture(dir: "gems/zebra")
        arguments = {
          gem_dirs: %w[gems/alpha gems/zebra],
          namespaces: {
            "gems/alpha" => "Julewire::Alpha",
            "gems/zebra" => "Julewire::Zebra"
          }
        }

        error = assert_raises(RuntimeError) do
          Julewire::Mutant::Targets.assert_fresh!(**arguments)
        end

        assert_equal(
          [
            "stale mutant target configs; run `rake mutant:targets`:",
            "gems/alpha/.mutant.yml",
            "gems/zebra/.mutant.yml"
          ].join("\n"),
          error.message
        )
      end
    end

    private

    def discovered_probe_subjects
      Julewire::Mutant::Targets.subjects_for(dir: "gems/probe", namespace: "Julewire::Probe")
    end

    def anonymous_method_shape_source
      <<~RUBY
        module Julewire::Probe
          Value = Data.define(:value) do
            def rendered = value.to_s
          end

          Patch = Module.new do
            def call = true
          end

          Worker = ::Class.new do
            def perform = true
          end

          Pair = ::Struct.new(:left, :right) do
            def combined = [left, right]
          end
        end
      RUBY
    end

    def nested_anonymous_method_shape_source
      <<~RUBY
        module Julewire::Probe
          Wrapper = Class.new do
            class Named
              def visible = true
            end

            module NamedModule
              def visible_module = true
            end

            Nested = Class.new do
              def hidden = true
            end
          end
        end
      RUBY
    end

    def reopened_root_extension_source
      <<~RUBY
        module Julewire
          module Facade
            def first
            end
          end

          extend Facade
        end
      RUBY
    end

    def root_constant_source
      <<~RUBY
        module Outside
          module Nested
          end
        end

        module Julewire
          module Zebra
          end

          class Alpha
          end

          Alias = String
          Config::DEFAULT = true
          ::Julewire::Absolute::VALUE = true
          Julewire::Rooted::VALUE = true
          ::Standalone = true
          module Nested::Deep
          end
        end
      RUBY
    end

    def root_extension_selection_source
      <<~RUBY
        module Julewire
          module RootFacade
            def root_method
            end
          end

          module NestedOnly
            def only_nested
            end
          end

          module IncludedOnly
            def only_included
            end
          end

          module ReceivedOnly
            def only_received
            end
          end

          extend RootFacade
          extend ExternalFacade
          include IncludedOnly
          self.extend ReceivedOnly
          extend

          module Nested
            module NestedFacade
              def only_nested
              end
            end

            extend NestedFacade
          end
        end
      RUBY
    end

    def root_extension_visibility_source
      <<~RUBY
        module Julewire
          module Facade
            private

            def hidden
            end

            public

            def first
            end

            protected

            def also_hidden
            end

            public

            def second
            end

            def self.not_instance
            end

            private :hidden

            def after_argument_visibility
            end

            private

            self.public

            def after_receiver_visibility
            end

            public

            decorate

            def after_non_visibility_call
            end
          end

          extend Facade
        end
      RUBY
    end

    def root_singleton_method_source
      <<~RUBY
        module Julewire
          module Nested
            def self.nested
            end
          end

          def self.direct
          end

          def Julewire.named
          end

          def Other.not_root
          end

          object = Object.new
          def object.dynamic_receiver
          end

          class << self
            SingletonOnly = true

            def singleton
            end
          end

          class << self
          end

          class << Other
            def foreign_singleton
            end
          end

          def method_with_nested_declarations
            def Julewire.nested_inside
            end
          end
        end
      RUBY
    end

    def build_mutant_target_fixture(dir: "gems/probe")
      namespace = File.basename(dir).capitalize
      write_temporary_repo_file("#{dir}/lib/julewire/probe.rb", "module Julewire::#{namespace}\nend\n")
      write_temporary_repo_file(
        "#{dir}/.mutant.yml",
        YAML.dump("usage" => "opensource", "matcher" => { "subjects" => ["Julewire::Stale*"] })
      )
    end
  end

  class TestQualityFlay < Minitest::Test
    cover Julewire::Quality::Flay

    def test_flay_baseline_check_reports_only_regressions
      error = assert_raises(RuntimeError) do
        Julewire::Quality::Flay.assert_baselines!(
          scores: { "gems/core" => 1, "gems/rack" => 0 },
          baselines: { "gems/core" => 0, "gems/rack" => 0 }
        )
      end

      expected_message = [
        "production Flay score regressions:",
        "gems/core: 1 (baseline 0)",
        "Run `rake all:flay_production_report` to inspect the production report."
      ].join("\n")

      assert_equal expected_message, error.message
    end

    def test_flay_baseline_check_accepts_current_scores
      assert_nil Julewire::Quality::Flay.assert_baselines!(
        scores: { "gems/core" => 0, "gems/rack" => 0 },
        baselines: { "gems/core" => 0, "gems/rack" => 0 }
      )
    end
  end
end
