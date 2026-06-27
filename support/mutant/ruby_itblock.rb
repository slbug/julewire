# frozen_string_literal: true

require "mutant"

module MutantRubyItBlockShim
  def for(type)
    return super(:numblock) if type.equal?(:itblock)

    super
  end
end

Mutant::AST::Structure.singleton_class.prepend(MutantRubyItBlockShim)
Mutant::Mutator::Node::Numblock.__send__(:handle, :itblock)
