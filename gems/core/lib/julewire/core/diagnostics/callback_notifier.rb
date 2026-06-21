# frozen_string_literal: true

module Julewire
  module Core
    module Diagnostics
      module CallbackNotifier
        ACTIVE_KEY = :__julewire_core_callback_active__
        private_constant :ACTIVE_KEY

        class NestedCallback < StandardError; end

        private_constant :NestedCallback

        Failure = Data.define(:at, :class_name, :metadata) do
          def to_h
            {
              action: metadata[:action],
              at: at,
              class: class_name,
              destination: metadata[:destination],
              phase: metadata[:phase],
              reason: metadata[:reason]
            }.compact.freeze
          end
        end

        class << self
          def call(callback, first_argument, metadata)
            return unless callback
            return nested_callback_result(metadata) if callback_active?

            previous = Fiber[ACTIVE_KEY]
            begin
              Fiber[ACTIVE_KEY] = true
              callback.call(first_argument, metadata)
              true
            rescue StandardError => e
              failure(e.class.name, metadata)
            ensure
              Fiber[ACTIVE_KEY] = previous
            end
          end

          def failure?(result)
            result.is_a?(Failure)
          end

          def nested_callback_result(metadata)
            failure(NestedCallback.name, metadata)
          end

          def callback_active?
            Fiber[ACTIVE_KEY] == true
          end

          def failure(class_name, metadata)
            Failure.new(at: Time.now.utc, class_name: class_name, metadata: metadata || {})
          end
        end
      end
    end
  end
end
