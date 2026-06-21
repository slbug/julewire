# frozen_string_literal: true

module Julewire
  module Core
    module Fields
      class StackSet
        EMPTY_HASH = {}.freeze
        private_constant :EMPTY_HASH

        class << self
          def inherit_from(source, inherit_attributes: true)
            stacks = Bags.stack_sections.to_h do |section|
              [section, inherited_stack(source, section, inherit_section?(section, inherit_attributes))]
            end
            new(**stacks)
          end

          private

          def inherit_section?(section, inherit_attributes)
            inherit_attributes || !%i[attributes neutral].include?(section)
          end

          def inherited_stack(source, section, inherit)
            inherit ? source.stack(section).fork : FieldStack.new
          end
        end

        def initialize(**sections)
          @stacks = Bags.stack_sections.to_h do |section|
            [section, field_stack(sections.fetch(section, EMPTY_HASH), section)]
          end.freeze
        end

        def stack(section)
          @stacks.fetch(section)
        end

        def snapshot(section)
          stack(section).snapshot
        end

        def add(section, fields, owned: false)
          stack(section).add(fields, owned: owned)
        end

        def delete(section, path)
          stack(section).delete(path)
        end

        def with(section, fields, owned: false, &)
          stack(section).with(fields, owned: owned, &)
        end

        def without(section, path, &)
          stack(section).without(path, &)
        end

        private

        def field_stack(value, section)
          return value if value.is_a?(FieldStack)

          FieldStack.new(value, delete_paths: Bags.delete_paths?(section))
        end
      end
    end
  end
end
