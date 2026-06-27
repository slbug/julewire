# frozen_string_literal: true

require "prism"

module Julewire
  module Quality
    module RubySource
      class << self
        def parse_file(path)
          result = Prism.parse_file(path)
          unless result.success?
            errors = result.errors.map { |error| "#{error.location.start_line}:#{error.message}" }.join("\n")
            raise "could not parse #{path}:\n#{errors}"
          end

          result
        end

        def each_node(root, &block)
          return enum_for(:each_node, root) unless block

          walk_node(root, &block)
        end

        def constant_name(node, path: nil, dynamic_constant_skips: nil)
          node.full_name
        rescue Prism::ConstantPathNode::DynamicPartsInConstantPathError
          line = node.start_line
          source = [path, line].compact.join(":")
          warning = "warning: skipping dynamic constant path in #{source}"
          warn warning
          raise warning unless dynamic_constant_skips

          dynamic_constant_skips << warning
          nil
        end

        private

        def walk_node(node, &)
          return unless node

          yield node
          node.child_nodes.each { |child| walk_node(child, &) }
        end

      end
    end
  end
end
