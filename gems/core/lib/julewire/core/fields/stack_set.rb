# frozen_string_literal: true

module Julewire
  module Core
    module Fields
      class StackSet
        class << self
          def inherit_from(source, inherit_attributes:)
            stacks = Bags.stack_sections.each_with_object({}) do |section, inherited|
              next unless inherit_section?(section, inherit_attributes)

              inherited[section] = source.stack(section).branch
            end
            new(**stacks)
          end

          private

          def inherit_section?(section, inherit_attributes)
            inherit_attributes || !%i[attributes neutral].include?(section)
          end
        end

        def initialize(**sections)
          @stacks = Bags.stack_sections.to_h do |section|
            [section, field_stack(sections.fetch(section, nil), section)]
          end
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

        def with(section, fields = nil, owned: false, **keyword_fields, &)
          stack(section).with(fields, owned: owned, **keyword_fields, &)
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
