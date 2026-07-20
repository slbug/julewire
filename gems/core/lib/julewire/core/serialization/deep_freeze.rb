# frozen_string_literal: true

module Julewire
  module Core
    module Serialization
      class DeepFreeze
        include ValueTraversal

        class << self
          def call(value, max_depth: NORMALIZATION_MAX_DEPTH, trust_frozen: false, validate_symbol_keys: false)
            validate_symbol_keys(value) if validate_symbol_keys
            new(max_depth, trust_frozen: trust_frozen).call(value)
          end

          def validate_symbol_keys(value)
            # WeakMap is identity-keyed and accepts new keys while enumerating,
            # so reachable containers form one finite work inventory without a
            # separate cycle-skip branch.
            containers = ObjectSpace::WeakMap.new
            containers[value] = nil if container?(value)
            containers.each_key do |current|
              if current.is_a?(Hash)
                current.each do |key, item|
                  validate_symbol_key!(key)
                  containers[item] = nil if container?(item)
                end
              else
                current.each { containers[it] = nil if container?(it) }
              end
            end
            value
          end

          def validate_symbol_hash(value)
            raise TypeError, "owned data must be a Hash" unless value.is_a?(Hash)

            validate_symbol_keys(value)
          end

          private

          def container?(value)
            value.is_a?(Hash) || value.is_a?(Array)
          end

          def validate_symbol_key!(key)
            raise TypeError, Fields::Internal::RECORD_STRING_KEY_ERROR if key.is_a?(String)
            raise TypeError, Fields::Internal::RECORD_SYMBOL_KEY_ERROR unless key.instance_of?(Symbol)
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
          value.freeze if value.is_a?(String)
          return value if @trust_frozen && value.frozen?
          return freeze_container(value, depth) if value.is_a?(Hash) || value.is_a?(Array)

          value
        end

        def freeze_container(value, depth)
          return Serializer::MAX_DEPTH_VALUE if depth_limited?(depth)

          with_traversal_container(value, value) do
            value.is_a?(Hash) ? freeze_hash(value, depth) : freeze_array(value, depth)
          end
        end

        def depth_limited?(depth)
          depth == @max_depth
        end

        def freeze_hash(value, depth)
          value.each do |key, item|
            freeze_child(value, key, item, depth)
          end
          value.freeze
        end

        def freeze_array(value, depth)
          value.each_index { freeze_child(value, it, value[it], depth) }
          value.freeze
        end

        def freeze_child(value, key, item, depth)
          frozen = freeze_value(item, depth + 1)
          value[key] = frozen unless value.frozen?
        end
      end
    end
  end
end
