# frozen_string_literal: true

module Julewire
  module Core
    module Serialization
      class DeepCompactEmpty
        include ValueTraversal

        class << self
          def call(value)
            ValueCopy.call(value, compact_empty: true)
          end

          def compact_owned!(value)
            new.compact_owned!(value)
          end

          def omitted?(value)
            ValueCopy.omitted_empty?(value)
          end
        end

        def compact_owned!(value)
          traverse(value) { |root, _depth| compact_value!(root) }
        end

        private

        def compact_value!(value)
          return compact_hash!(value) if value.is_a?(Hash)
          return compact_array!(value) if value.is_a?(Array)

          value
        end

        def compact_hash!(value)
          with_traversal_container(value, value) do
            value.each do |key, item|
              compacted = compact_value!(item)
              if self.class.omitted?(compacted)
                value.delete(key)
              elsif !compacted.equal?(item)
                value[key] = compacted
              end
            end
            value
          end
        end

        def compact_array!(value)
          with_traversal_container(value, value) do
            index = 0
            value.each do |item|
              compacted = compact_value!(item)
              next if self.class.omitted?(compacted)

              value[index] = compacted
              index += 1
            end
            value.slice!(index, value.length - index) if index < value.length
            value
          end
        end
      end
    end
  end
end
