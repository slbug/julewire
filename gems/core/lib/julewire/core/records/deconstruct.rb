# frozen_string_literal: true

module Julewire
  module Core
    module Records
      module Deconstruct
        # Host record classes expose their immutable field hash through @data.
        def deconstruct_keys(keys)
          return to_h unless keys

          keys.each_with_object({}) do |key, selected|
            selected[key] = Fields::FieldSet.deep_dup(@data[key]) if @data.key?(key)
          end
        end
      end
      private_constant :Deconstruct
    end
  end
end
