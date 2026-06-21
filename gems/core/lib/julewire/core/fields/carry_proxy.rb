# frozen_string_literal: true

module Julewire
  module Core
    module Fields
      class CarryProxy < SectionProxy
        def initialize(store) = super(store, :carry)

        def delete(*path)
          @store.delete_carry(path)
          self
        end

        def without(*path, &)
          raise ArgumentError, "block required" unless block_given?

          @store.without_carry(path, &)
        end
      end
    end
  end
end
