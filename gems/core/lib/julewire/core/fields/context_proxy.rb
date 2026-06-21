# frozen_string_literal: true

module Julewire
  module Core
    module Fields
      class ContextProxy < SectionProxy
        def initialize(store) = super(store, :context)
      end
    end
  end
end
