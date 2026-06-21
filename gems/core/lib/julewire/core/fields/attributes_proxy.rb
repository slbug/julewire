# frozen_string_literal: true

module Julewire
  module Core
    module Fields
      class AttributesProxy < SectionProxy
        def initialize(store) = super(store, :attributes)
      end
    end
  end
end
