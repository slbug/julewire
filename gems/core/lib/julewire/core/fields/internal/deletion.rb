# frozen_string_literal: true

module Julewire
  module Core
    module Fields
      module Internal
        module Deletion
          class << self
            def delete_path!(target, path)
              normalized_path = normalize_path(path)
              return target if normalized_path.empty?

              deep_delete_path!(target, normalized_path)
              target
            end

            def apply_delete_paths!(target, paths)
              paths.each { delete_path!(target, it) }
              target
            end

            def clear_delete_paths!(paths, fields)
              additions = field_paths(fields)
              paths.reject! do |path|
                additions.any? { path_overlap?(path, it) }
              end
            end

            def normalize_path(path)
              Array(path).flatten.filter_map { Internal.normalize_key(it) }
            end

            private

            def field_paths(fields, prefix = [])
              return [] unless fields.is_a?(Hash)

              fields.flat_map do |key, value|
                path = prefix + [Internal.normalize_key(key)]
                nested = value.is_a?(Hash) ? field_paths(value, path) : []
                nested.empty? ? [path] : nested
              end
            end

            def path_overlap?(left, right)
              shortest = [left.length, right.length].min
              left.first(shortest) == right.first(shortest)
            end

            def deep_delete_path!(target, path)
              return unless target.is_a?(Hash)

              key = path.first
              if path.one?
                Internal.delete_key!(target, key)
                return
              end

              child = FieldSet.value_for(target, key)
              deep_delete_path!(child, path.drop(1))
              Internal.delete_key!(target, key) if child.is_a?(Hash) && child.empty?
            end
          end
        end
      end
    end
  end
end
