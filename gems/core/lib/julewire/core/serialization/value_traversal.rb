# frozen_string_literal: true

module Julewire
  module Core
    module Serialization
      module ValueTraversal
        def traverse(value)
          previous_seen = @traversal_seen
          previous_first_seen = @traversal_first_seen
          previous_second_seen = @traversal_second_seen
          previous_third_seen = @traversal_third_seen
          previous_fourth_seen = @traversal_fourth_seen
          @traversal_seen = nil
          @traversal_first_seen = nil
          @traversal_second_seen = nil
          @traversal_third_seen = nil
          @traversal_fourth_seen = nil
          yield(value, 0)
        ensure
          @traversal_seen = previous_seen
          @traversal_first_seen = previous_first_seen
          @traversal_second_seen = previous_second_seen
          @traversal_third_seen = previous_third_seen
          @traversal_fourth_seen = previous_fourth_seen
        end

        private

        def with_traversal_container(value, circular_value)
          added = false
          seen = @traversal_seen
          first_seen = @traversal_first_seen
          second_seen = @traversal_second_seen
          third_seen = @traversal_third_seen
          fourth_seen = @traversal_fourth_seen
          return circular_value if seen&.key?(value) || first_seen.equal?(value) || second_seen.equal?(value) ||
                                   third_seen.equal?(value) || fourth_seen.equal?(value)

          added = mark_traversal_container(value, seen, first_seen, second_seen, third_seen, fourth_seen)
          yield
        ensure
          unmark_traversal_container(value, added)
        end

        def traversal_seen?(value)
          @traversal_seen&.key?(value) || @traversal_first_seen.equal?(value) ||
            @traversal_second_seen.equal?(value) || @traversal_third_seen.equal?(value) ||
            @traversal_fourth_seen.equal?(value)
        end

        def with_marked_traversal_container(value)
          added = mark_traversal_container(
            value,
            @traversal_seen,
            @traversal_first_seen,
            @traversal_second_seen,
            @traversal_third_seen,
            @traversal_fourth_seen
          )
          yield
        ensure
          unmark_traversal_container(value, added)
        end

        def mark_traversal_container(value, seen, first_seen, second_seen, third_seen, fourth_seen)
          # Most records visit only a handful of live containers. Keep those in
          # slots and allocate the identity hash only for genuinely deep walks.
          if seen
            seen[value] = true
            :hash
          elsif first_seen.nil?
            mark_first_seen(value)
          elsif second_seen.nil?
            mark_second_seen(value)
          elsif third_seen.nil?
            mark_third_seen(value)
          elsif fourth_seen.nil?
            mark_fourth_seen(value)
          else
            promote_traversal_seen(value, first_seen, second_seen, third_seen, fourth_seen)
          end
        end

        def unmark_traversal_container(value, added)
          case added
          when :hash
            @traversal_seen.delete(value)
          when :first, :second, :third, :fourth
            unmark_traversal_slot(value, added)
          end
        end

        def mark_first_seen(value)
          @traversal_first_seen = value
          :first
        end

        def mark_second_seen(value)
          @traversal_second_seen = value
          :second
        end

        def mark_third_seen(value)
          @traversal_third_seen = value
          :third
        end

        def mark_fourth_seen(value)
          @traversal_fourth_seen = value
          :fourth
        end

        def promote_traversal_seen(value, first_seen, second_seen, third_seen, fourth_seen)
          @traversal_seen = {}.compare_by_identity
          @traversal_seen[first_seen] = true
          @traversal_seen[second_seen] = true
          @traversal_seen[third_seen] = true
          @traversal_seen[fourth_seen] = true
          @traversal_seen[value] = true
          clear_traversal_slots!
          :hash
        end

        def unmark_traversal_slot(value, added)
          return @traversal_seen.delete(value) if @traversal_seen

          clear_traversal_slot(added)
        end

        def clear_traversal_slot(slot)
          case slot
          when :first then @traversal_first_seen = nil
          when :second then @traversal_second_seen = nil
          when :third then @traversal_third_seen = nil
          when :fourth then @traversal_fourth_seen = nil
          end
        end

        def clear_traversal_slots!
          @traversal_first_seen = nil
          @traversal_second_seen = nil
          @traversal_third_seen = nil
          @traversal_fourth_seen = nil
        end
      end

      private_constant :ValueTraversal
    end
  end
end
