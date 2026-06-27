# frozen_string_literal: true

require "yaml"
require_relative "../quality/ruby_source"

module Julewire
  module Mutant
    module Targets
      class << self
        def update!(gem_dirs:, namespaces:, additional_subjects: {})
          gem_dirs.each do |dir|
            subjects = subjects_for(
              dir: dir,
              namespace: namespaces.fetch(dir),
              additional_subjects: additional_subjects.fetch(dir, [])
            )
            update_config!(dir, subjects)
          end
          nil
        end

        def assert_fresh!(gem_dirs:, namespaces:, additional_subjects: {})
          stale = gem_dirs.filter_map do |dir|
            path = config_path(dir)
            subjects = subjects_for(
              dir: dir,
              namespace: namespaces.fetch(dir),
              additional_subjects: additional_subjects.fetch(dir, [])
            )
            expected = render_config(updated_config(dir, subjects))
            path unless File.read(path).eql?(expected)
          end
          return if stale.empty?

          raise "stale mutant target configs; run `rake mutant:targets`:\n#{stale.join("\n")}"
        end

        def assert_runtime_subjects!(requirements:, subject_lists:)
          missing = requirements.flat_map do |dir, required_subjects|
            required_subjects.filter_map do |subject|
              "#{dir}: #{subject}" unless subject_lists.fetch(dir).include?(subject)
            end
          end
          return if missing.empty?

          raise "production methods missing from Mutant runtime inventory:\n#{missing.join("\n")}"
        end

        def assert_visible_method_shapes!(gem_dirs:, allowed_class_body_define_method_counts: {})
          paths = gem_dirs.flat_map { |dir| Dir.glob(File.join(dir, "lib/**/*.rb")) }
          anonymous_method_definitions = []
          class_body_define_methods = Hash.new { |hash, path| hash[path] = [] }

          paths.each do |path|
            scan = MethodShapeScan.new(path).call
            anonymous_method_definitions.concat(scan.fetch(:anonymous_method_definitions))
            class_body_define_methods[path].concat(scan.fetch(:class_body_define_methods))
          end

          dynamic_mismatches = (class_body_define_methods.keys | allowed_class_body_define_method_counts.keys).filter_map do |path|
            lines = class_body_define_methods.fetch(path, [])
            expected = allowed_class_body_define_method_counts.fetch(path, 0)
            next if lines.length == expected

            "#{path}: expected #{expected} class-body define_method call(s), found #{lines.length} at #{lines.join(", ")}"
          end
          offenders = anonymous_method_definitions + dynamic_mismatches
          return if offenders.empty?

          raise "production method bodies must be visible to Mutant:\n#{offenders.join("\n")}"
        end

        def subjects_for(dir:, namespace:, additional_subjects: [])
          discovered = Discovery.new(dir).call
          subjects = ["#{namespace}*"]
          subjects.concat(discovered.root_constants.map { |constant| "#{constant}*" })
          subjects.concat(discovered.root_methods)
          subjects.concat(additional_subjects)
          subjects.uniq.sort
        end

        private

        def update_config!(dir, subjects)
          path = config_path(dir)
          config = updated_config(dir, subjects)
          File.write(path, render_config(config))
        end

        def updated_config(dir, subjects)
          config = YAML.safe_load_file(config_path(dir))
          config["matcher"] ||= {}
          config.fetch("matcher")["subjects"] = subjects
          config
        end

        def config_path(dir)
          File.join(dir, ".mutant.yml")
        end

        def render_config(config)
          YAML.dump(config)
        end
      end

      Discovered = Data.define(:root_constants, :root_methods)

      class MethodShapeScan
        ANONYMOUS_METHOD_OWNERS = {
          "Class" => :new,
          "Data" => :define,
          "Module" => :new,
          "Struct" => :new
        }.freeze
        private_constant :ANONYMOUS_METHOD_OWNERS

        def initialize(path)
          @path = path
        end

        def call
          root = Quality::RubySource.parse_file(@path).value
          {
            anonymous_method_definitions: anonymous_method_definitions(root),
            class_body_define_methods: class_body_define_methods(root)
          }
        end

        private

        def anonymous_method_definitions(root)
          offenders = []
          Quality::RubySource.each_node(root) do |node|
            owner = anonymous_method_owner(node)
            next unless owner

            collect_anonymous_method_definitions(node.block, owner, node.name, offenders)
          end
          offenders
        end

        def collect_anonymous_method_definitions(node, owner, factory, offenders)
          return unless node
          return if node.instance_of?(Prism::ClassNode) || node.instance_of?(Prism::ModuleNode)
          return if anonymous_method_owner(node)

          if node.instance_of?(Prism::DefNode)
            offenders << "#{@path}:#{node.start_line}:#{node.name} is defined inside #{owner}.#{factory}"
          end

          node.compact_child_nodes.each do |child|
            collect_anonymous_method_definitions(child, owner, factory, offenders)
          end
        end

        def anonymous_method_owner(node)
          return unless node.instance_of?(Prism::CallNode)
          return unless node.receiver.instance_of?(Prism::ConstantReadNode) ||
                        node.receiver.instance_of?(Prism::ConstantPathNode)

          owner = Quality::RubySource.constant_name(node.receiver).delete_prefix("::")
          owner if ANONYMOUS_METHOD_OWNERS[owner] == node.name
        end

        def class_body_define_methods(root)
          lines = []
          scan_class_body_define_methods(root, lines)
          lines
        end

        def scan_class_body_define_methods(node, lines)
          return if node.instance_of?(Prism::DefNode)

          if node.instance_of?(Prism::CallNode) && node.name == :define_method
            lines << node.start_line
          end
          node.compact_child_nodes.each do |child|
            scan_class_body_define_methods(child, lines)
          end
        end
      end

      class Discovery
        def initialize(dir)
          @dir = dir
          @root_constants = []
          @root_extends = []
          @root_methods = []
          @instance_methods_by_owner = Hash.new { |hash, key| hash[key] = [] }
        end

        def call
          Dir.glob(File.join(@dir, "lib/**/*.rb")) { |path| scan_file(path) }
          collect_root_extension_methods
          Discovered.new(root_constants: @root_constants, root_methods: @root_methods)
        end

        private

        def scan_file(path)
          result = Quality::RubySource.parse_file(path)
          scan(result.value, namespace: nil)
        end

        def scan(node, namespace:)
          return unless node

          case node
          when Prism::ClassNode, Prism::ModuleNode
            scan_constant_container(node, namespace)
            return
          when Prism::SingletonClassNode
            scan_singleton_class(node, namespace)
            return
          when Prism::DefNode
            scan_definition(node, namespace, nil)
            return
          when Prism::ConstantWriteNode
            collect_root_constant("#{namespace}::#{node.name}")
          when Prism::ConstantPathWriteNode
            collect_root_constant_path(constant_name(node.target, namespace))
          when Prism::CallNode
            collect_root_extend(node, namespace)
          end
          scan_children(node, namespace:)
        end

        def scan_constant_container(node, namespace)
          name = constant_name(node.constant_path, namespace)
          collect_root_constant(name)
          collect_public_instance_methods(name, node.body)
          scan(node.body, namespace: name)
        end

        def scan_singleton_class(node, namespace)
          root_owner = root_receiver?(node.expression, namespace)
          node.body&.body&.each do |statement|
            scan_definition(statement, nil, root_owner) if statement.instance_of?(Prism::DefNode)
          end
        end

        def scan_definition(node, namespace, singleton_root_owner)
          root_owner = root_receiver?(node.receiver, namespace) || singleton_root_owner
          @root_methods << "Julewire.#{node.name}" if root_owner
        end

        def scan_children(node, namespace:)
          node.compact_child_nodes.each { |child| scan(child, namespace:) }
        end

        def collect_root_constant(name)
          parts = name.split("::")
          @root_constants << name if parts.length == 2 && parts.first == "Julewire"
        end

        def collect_root_constant_path(name)
          parts = name.split("::")
          collect_root_constant(parts.first(2).join("::"))
        end

        def collect_root_extend(node, namespace)
          return unless namespace == "Julewire"
          return unless node.receiver.nil?
          return unless node.name == :extend

          node.arguments&.arguments&.each do |argument|
            @root_extends << constant_name(argument, namespace)
          end
        end

        def collect_root_extension_methods
          @root_extends.each do |owner|
            @instance_methods_by_owner[owner].each { |method| @root_methods << "Julewire.#{method}" }
          end
        end

        def collect_public_instance_methods(owner, body)
          return unless body

          visibility = :public
          body.body.each do |statement|
            case statement
            when Prism::DefNode
              if visibility == :public && statement.receiver.nil?
                @instance_methods_by_owner[owner] << statement.name
              end
            when Prism::CallNode
              visibility = statement.name if visibility_marker?(statement)
            end
          end
        end

        def visibility_marker?(node)
          node.receiver.nil? &&
            node.arguments.nil? &&
            %i[private protected public].include?(node.name)
        end

        def root_receiver?(node, namespace)
          case node
          when Prism::SelfNode
            namespace == "Julewire"
          when Prism::ConstantReadNode
            Quality::RubySource.constant_name(node) == "Julewire"
          end
        end

        def constant_name(node, namespace)
          name = Quality::RubySource.constant_name(node).delete_prefix("::")
          return name if node.slice.start_with?("::")
          return name if name == "Julewire" || name.start_with?("Julewire::")
          "#{namespace}::#{name}"
        end
      end
    end
  end
end
