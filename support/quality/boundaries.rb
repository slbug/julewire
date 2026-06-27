# frozen_string_literal: true

require "set"
require_relative "ruby_source"

module Julewire
  module Quality
    module Boundaries
      BUILT_IN_OBJECT_METHOD_NAMES = (
        Object.instance_methods(true) +
        Object.private_instance_methods(true) +
        Kernel.instance_methods(true) +
        Kernel.private_instance_methods(true)
      ).to_set.freeze
      private_constant :BUILT_IN_OBJECT_METHOD_NAMES

      class << self
        def assert_core_neutrality(allowed_constants:, allowed_constants_by_path:, core_public_alias_prefixes:)
          dynamic_constant_skips = []
          offenders = Dir.glob("gems/core/lib/**/*.rb").flat_map do |path|
            references = ruby_constant_references(path, dynamic_constant_skips: dynamic_constant_skips)
            references.filter_map do |reference, line|
              if core_reference_forbidden?(
                path,
                reference,
                allowed_constants,
                allowed_constants_by_path,
                core_public_alias_prefixes
              )
                "#{path}:#{line}:#{reference}"
              end
            end
          end
          assert_no_dynamic_constant_skips!(dynamic_constant_skips)
          return if offenders.empty?

          raise "core must use only core, stdlib, and declared dependency constants:\n#{offenders.join("\n")}"
        end

        def assert_integration_boundaries(integration_dirs:, integration_namespaces:, integration_allowed_references:,
                                          core_public_alias_prefixes:, core_spi_allowed_prefixes:,
                                          core_bridge_allowed_prefixes:)
          checker = IntegrationChecker.new(
            integration_namespaces: integration_namespaces,
            integration_allowed_references: integration_allowed_references,
            core_public_alias_prefixes: core_public_alias_prefixes,
            core_spi_allowed_prefixes: core_spi_allowed_prefixes,
            core_bridge_allowed_prefixes: core_bridge_allowed_prefixes
          )
          dynamic_constant_skips = []
          offenders = integration_dirs.flat_map do |dir|
            Dir.glob(File.join(dir, "lib/**/*.rb")).flat_map do |path|
              references = ruby_constant_references(path, dynamic_constant_skips: dynamic_constant_skips)
              references.flat_map do |reference, line|
                checker.offenders(dir, path, line, reference)
              end
            end
          end

          assert_no_dynamic_constant_skips!(dynamic_constant_skips)
          return if offenders.empty?

          raise "integration gems must use documented Core SPI:\n#{offenders.join("\n")}"
        end

        def assert_safe_method_names(paths:, allowed_method_names:)
          forbidden = inherited_object_method_names - allowed_method_names
          offenders = paths.flat_map do |path|
            result = RubySource.parse_file(path)
            RubySource.each_node(result.value).filter_map do |node|
              next unless node.instance_of?(Prism::DefNode) && forbidden.include?(node.name)

              "#{path}:#{node.start_line}:#{node.name}"
            end
          end
          return if offenders.empty?

          raise "production methods must not collide with Object or Kernel:\n#{offenders.sort.join("\n")}"
        end

        private

        def inherited_object_method_names
          BUILT_IN_OBJECT_METHOD_NAMES
        end

        def core_reference_forbidden?(
          path,
          reference,
          allowed_constants,
          allowed_constants_by_path,
          core_public_alias_prefixes
        )
          # Public for the Rakefile guard; `Julewire::Core::` must not admit `Julewire::CoreBad`.
          constant = reference.delete_prefix("::")
          return false if allowed_core_constant_reference?(constant, core_public_alias_prefixes)

          root = constant.split("::").first
          return true if root == "Julewire"
          return false if root == "Core"
          return false if allowed_constants.include?(root)
          return false if allowed_constants_by_path.fetch(path, []).include?(root)
          return false if core_local_constant_roots.include?(root)

          true
        end

        def allowed_core_constant_reference?(constant, core_public_alias_prefixes)
          constant == "Julewire" ||
            constant == "Julewire::Core" ||
            constant.start_with?("Julewire::Core::") ||
            allowed_core_public_alias?(constant, core_public_alias_prefixes)
        end

        def allowed_core_public_alias?(constant, core_public_alias_prefixes)
          core_public_alias_prefixes.any? do |prefix|
            constant == prefix || constant.start_with?("#{prefix}::")
          end
        end

        def core_local_constant_roots
          Dir.glob("gems/core/lib/**/*.rb").flat_map do |path|
            ruby_constant_definitions(path).map do |constant|
              constant.to_s.split("::").first
            end
          end
        end

        def ruby_constant_references(path, dynamic_constant_skips:)
          result = RubySource.parse_file(path)
          references = []
          collect_ruby_constant_references(result.value, references, path, dynamic_constant_skips)
          longest_constant_references(references)
        end

        def ruby_constant_definitions(path)
          result = RubySource.parse_file(path)
          definitions = []
          collect_ruby_constant_definitions(result.value, definitions)
          definitions
        end

        def collect_ruby_constant_references(root, references, path, dynamic_constant_skips)
          RubySource.each_node(root) do |node|
            case node
            when Prism::ConstantPathNode, Prism::ConstantReadNode
              if (constant_name = ruby_constant_name(node, path, dynamic_constant_skips))
                references << [constant_name, node.start_line]
              end
            end
          end
        end

        def collect_ruby_constant_definitions(root, definitions)
          RubySource.each_node(root) do |node|
            case node
            when Prism::ClassNode, Prism::ModuleNode
              definitions << RubySource.constant_name(node.constant_path)
            when Prism::ConstantWriteNode
              definitions << node.name
            when Prism::ConstantPathWriteNode
              definitions << RubySource.constant_name(node.target)
            end
          end
        end

        def ruby_constant_name(node, path, dynamic_constant_skips)
          RubySource.constant_name(node, path:, dynamic_constant_skips: dynamic_constant_skips)
        end

        def assert_no_dynamic_constant_skips!(skips)
          return if skips.empty?

          raise "unexpected dynamic constant path skips:\n#{skips.join("\n")}"
        end

        def longest_constant_references(references)
          references.group_by(&:last).flat_map do |line, line_references|
            names = line_references.map(&:first)
            names.reject { |name| names.any? { |other| other.start_with?("#{name}::") } }
                 .map { |name| [name, line] }
          end
        end
      end

      class IntegrationChecker
        def initialize(integration_namespaces:, integration_allowed_references:, core_public_alias_prefixes:,
                       core_spi_allowed_prefixes:, core_bridge_allowed_prefixes:)
          @integration_namespaces = integration_namespaces
          @integration_allowed_references = integration_allowed_references
          @core_public_alias_prefixes = core_public_alias_prefixes
          @core_spi_allowed_prefixes = core_spi_allowed_prefixes
          @core_bridge_allowed_prefixes = core_bridge_allowed_prefixes
          @julewire_bareword_prefixes = integration_namespaces.values.to_h do |reference|
            [reference.split("::").last, reference]
          end
        end

        def offenders(dir, path, line, reference)
          core_reference_offenders(dir, path, line, reference) +
            public_alias_offenders(dir, path, line, reference)
        end

        private

        def core_reference_offenders(dir, path, line, reference)
          core_reference = normalized_core_reference(reference)
          return [] unless core_reference
          return [] if allowed_core_reference?(dir, core_reference)

          ["#{path}:#{line}:#{core_reference}"]
        end

        def public_alias_offenders(dir, path, line, reference)
          julewire_public_references(reference).filter_map do |julewire_reference|
            next if julewire_reference.start_with?("Julewire::Core::")
            next if julewire_reference == "Julewire::Core"
            next if allowed_julewire_reference?(dir, julewire_reference)

            "#{path}:#{line}:#{julewire_reference}"
          end
        end

        def normalized_core_reference(reference)
          reference = reference.delete_prefix("::")
          if reference.start_with?("Julewire::Core::")
            reference.delete_prefix("Julewire::")
          elsif reference.start_with?("Core::")
            reference
          end
        end

        def allowed_core_reference?(dir, reference)
          allowed_core_prefix?(reference, @core_spi_allowed_prefixes) ||
            (dir == "gems/ractor" && allowed_core_prefix?(reference, @core_bridge_allowed_prefixes))
        end

        def allowed_julewire_reference?(dir, reference)
          allowed_core_prefix?(reference, [@integration_namespaces.fetch(dir)]) ||
            allowed_core_prefix?(reference, @integration_allowed_references.fetch(dir, [])) ||
            allowed_core_prefix?(reference, @core_public_alias_prefixes)
        end

        def julewire_public_references(reference)
          return [reference.delete_prefix("::")] if reference.start_with?("::Julewire::")
          return [reference] if reference.start_with?("Julewire::")

          root, separator, suffix = reference.partition("::")
          prefix = @julewire_bareword_prefixes[root]
          return [] unless prefix

          ["#{prefix}#{separator}#{suffix}"]
        end

        def allowed_core_prefix?(reference, prefixes)
          prefixes.any? { |prefix| reference == prefix || reference.start_with?("#{prefix}::") }
        end
      end
    end
  end
end
