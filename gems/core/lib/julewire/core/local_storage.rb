# frozen_string_literal: true

require "concurrent/atomic/atomic_reference"

module Julewire
  module Core
    # @api internal
    # Process/ractor-local storage for facade lookups. The ractor bridge can set
    # the current runtime from inside a child ractor, but the getter side still
    # runs inside core through Julewire.* facade calls.
    module LocalStorage
      RUNTIME_KEY = :__julewire_core_runtime__
      CONTEXT_STORE_THREAD_KEY = :__julewire_core_context_store__
      CONTEXT_STORE_FIBER_IVAR = :@__julewire_core_context_store__
      private_constant :RUNTIME_KEY, :CONTEXT_STORE_THREAD_KEY, :CONTEXT_STORE_FIBER_IVAR

      @runtime_ref = Concurrent::AtomicReference.new
      @runtime_mutex = Mutex.new

      class << self
        def runtime
          return ractor_runtime if ractor_local_storage?

          runtime_ref.get || runtime_mutex.synchronize do
            runtime_ref.get || Runtime.new.tap { runtime_ref.set(it) }
          end
        end

        def runtime=(runtime)
          if ractor_local_storage?
            ::Ractor[RUNTIME_KEY] = runtime
          else
            runtime_ref.set(runtime)
          end
        end

        def context_store
          context_store_value || store_context(ContextStore.new)
        end

        def reset_context_store!
          store_context(nil)
        end

        def after_fork!
          runtime = runtime_ref.get
          @runtime_mutex = Mutex.new
          @runtime_ref = Concurrent::AtomicReference.new(runtime)
          nil
        end

        # Private testing seam for storage-selection behavior.
        def main_ractor?
          ::Ractor.main?
        end
        private :main_ractor?

        private

        attr_reader :runtime_mutex, :runtime_ref

        def ractor_runtime
          ::Ractor.store_if_absent(RUNTIME_KEY) { Runtime.new }
        end

        def context_store_value
          if ractor_local_storage?
            # Child-ractor bridge work is thread-scoped; main-ractor app work is fiber-scoped.
            Thread.current[CONTEXT_STORE_THREAD_KEY]
          else
            # Do not use Fiber#storage here: child fibers inherit it by default,
            # while Julewire context only propagates through Julewire.fiber.
            Fiber.current.instance_variable_get(CONTEXT_STORE_FIBER_IVAR)
          end
        end

        def store_context(value)
          if ractor_local_storage?
            Thread.current[CONTEXT_STORE_THREAD_KEY] = value
          else
            Fiber.current.instance_variable_set(CONTEXT_STORE_FIBER_IVAR, value)
          end
        end

        def ractor_local_storage?
          !main_ractor?
        end
      end
    end
  end
end
