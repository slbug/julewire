# frozen_string_literal: true

module Julewire
  module Core
    module Serialization
      module ValueTraversal
        def traverse(value)
          yield(value, 0)
        end

        private

        def with_traversal_container(value, circular_value, &)
          seen = traversal_seen
          return circular_value if seen.include?(value)

          seen.add(value)
          begin
            yield
          ensure
            seen.delete(value)
          end
        end

        def traversal_seen
          @traversal_seen ||= Set.new.compare_by_identity
        end
      end

      private_constant :ValueTraversal
    end
  end
end
