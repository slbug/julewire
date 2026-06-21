# frozen_string_literal: true

module Julewire
  module Core
    module Serialization
      class DeepFreeze
        include ValueTraversal

        class << self
          def call(value, max_depth: Core::NORMALIZATION_MAX_DEPTH, trust_frozen: false)
            new(max_depth, trust_frozen: trust_frozen).call(value)
          end
        end

        def initialize(max_depth, trust_frozen:)
          @max_depth = max_depth
          @trust_frozen = trust_frozen
        end

        def call(value)
          traverse(value) { |root, depth| freeze_value(root, depth) }
        end

        private

        def freeze_value(value, depth)
          return value.freeze if value.is_a?(String)
          return value if @trust_frozen && value.frozen?
          return freeze_container(value, depth) if value.is_a?(Hash) || value.is_a?(Array)

          value
        end

        def freeze_container(value, depth)
          return Serializer::MAX_DEPTH_VALUE.freeze if depth_limited?(depth)

          with_traversal_container(value, value) do
            value.is_a?(Hash) ? freeze_hash(value, depth) : freeze_array(value, depth)
          end
        end

        def depth_limited?(depth)
          @max_depth && depth >= @max_depth
        end

        def freeze_hash(value, depth)
          value.each { |key, item| freeze_child(value, key, item, depth) }
          value.freeze
        end

        def freeze_array(value, depth)
          value.each_index { freeze_child(value, it, value[it], depth) }
          value.freeze
        end

        def freeze_child(value, key, item, depth)
          frozen = freeze_value(item, depth + 1)
          value[key] = frozen unless value.frozen? || frozen.equal?(item)
        end
      end
    end
  end
end
