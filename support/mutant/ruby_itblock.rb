# frozen_string_literal: true

require "mutant"

module Julewire
  module MutantRubyItBlock
    def for(type)
      return super(:numblock) if type.equal?(:itblock)

      super
    end
  end
end

Mutant::AST::Structure.singleton_class.prepend(Julewire::MutantRubyItBlock)
Mutant::Mutator::Node::Numblock.__send__(:handle, :itblock)
