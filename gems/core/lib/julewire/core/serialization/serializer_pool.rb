# frozen_string_literal: true

module Julewire
  module Core
    module Serialization
      module SerializerPool
        class << self
          def serializer(pool_key, serializer_key)
            # Serializers carry traversal state, so pooled instances stay thread-local.
            pool = Thread.current.thread_variable_get(pool_key)
            unless pool
              pool = {}
              Thread.current.thread_variable_set(pool_key, pool)
            end
            pool[serializer_key] ||= yield
          end

          def serialize(pool_key, serializer_key, payload, &)
            serialize_with(serializer(pool_key, serializer_key, &), payload, &)
          end

          def serialize_with(serializer, payload)
            serializer = yield if serializer.in_use?
            serializer.serialize(payload)
          end
        end
      end
    end
  end
end
