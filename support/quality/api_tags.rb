# frozen_string_literal: true

require_relative "ruby_source"

module Julewire
  module Quality
    module ApiTags
      class << self
        def assert!(tag_values:, requirements:)
          offenders = invalid_tag_offenders(tag_values) + missing_tag_offenders(requirements)
          return if offenders.empty?

          raise "invalid @api tags:\n#{offenders.join("\n")}"
        end

        private

        def invalid_tag_offenders(tag_values)
          Dir.glob("gems/*/lib/**/*.rb").flat_map do |path|
            api_tags(parse_ruby(path)).filter_map do |tag|
              invalid_tag_offender(tag, tag_values, path)
            end
          end
        end

        def invalid_tag_offender(tag, tag_values, path)
          if !tag_values.include?(tag.value)
            "#{path}:#{tag.line}:unknown #{tag.value}"
          elsif !tag.target
            "#{path}:#{tag.line}:not attached to class/module/def"
          end
        end

        def missing_tag_offenders(requirements)
          requirements.flat_map do |path, required_tags|
            tagged = tagged_targets(parse_ruby(path))
            required_tags.filter_map do |target, tag|
              tags = tagged[target]
              next if !tags.empty? && tags.all? { |actual_tag| actual_tag == tag }

              "#{path}:#{target}:missing @api #{tag}"
            end
          end
        end

        ApiTag = Data.define(:line, :value, :target)
        ApiTarget = Data.define(:node, :name)
        private_constant :ApiTag, :ApiTarget

        def tagged_targets(result)
          tags_by_target = api_tags(result).to_h { |api_tag| [api_tag.target, api_tag.value] }
          tag_target_nodes(result.value).each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |node, targets|
            target = api_target(node)
            targets[target.name] << tags_by_target[target]
          end
        end

        def api_tags(result)
          target_nodes = tag_target_nodes(result.value)
          all_nodes = RubySource.each_node(result.value)
          result.comments.filter_map do |comment|
            match = api_tag_match(comment)
            next unless match

            line = comment.location.start_line
            ApiTag.new(line:, value: match[1], target: attached_target_name(line, target_nodes, all_nodes))
          end
        end

        def parse_ruby(path)
          RubySource.parse_file(path)
        end

        def api_tag_match(comment)
          comment.slice.match(/\A#\s+@api\s+(\S+)/)
        end

        def attached_target_name(line, target_nodes, all_nodes)
          target_line = next_source_line(line, all_nodes)
          target = target_nodes.find { |node| node.start_line == target_line }
          api_target(target) if target
        end

        def next_source_line(line, nodes)
          nodes.find { |node| node.start_line > line }&.start_line
        end

        def tag_target_nodes(root)
          RubySource.each_node(root).select { |node| tag_target_node?(node) }
        end

        def tag_target_node?(node)
          node.instance_of?(Prism::ClassNode) ||
            node.instance_of?(Prism::ModuleNode) ||
            node.instance_of?(Prism::DefNode)
        end

        def api_target(node)
          ApiTarget.new(node, tag_definition_name(node))
        end

        def tag_definition_name(node)
          case node
          when Prism::ClassNode, Prism::ModuleNode
            ruby_constant_name(node.constant_path).split("::").last
          when Prism::DefNode
            node.name.to_s
          end
        end

        def ruby_constant_name(node)
          RubySource.constant_name(node)
        end
      end
    end
  end
end
