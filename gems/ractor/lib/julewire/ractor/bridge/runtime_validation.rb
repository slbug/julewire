# frozen_string_literal: true

module Julewire
  module Ractor
    module Bridge
      module RuntimeValidation
        REQUIRED_METHODS = %i[
          emit_envelope
          emit_summary_record
          flush
        ].freeze

        class << self
          def validate!(runtime)
            missing = REQUIRED_METHODS.reject { runtime.respond_to?(it) }
            return if missing.empty?

            raise ArgumentError, "Julewire.ractor requires a bridge-compatible runtime " \
                                 "(missing: #{missing.join(", ")})"
          end
        end
      end
    end
  end
end
