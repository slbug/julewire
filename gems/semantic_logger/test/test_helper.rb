# frozen_string_literal: true

require "julewire/core/testing/coverage"
Julewire::Core::Testing::Coverage.start!

require "julewire/semantic_logger"
require "julewire/core/testing"

require "minitest/autorun"
require "mutant/minitest/coverage"
require "stringio"

module Minitest
  class Test
    include Julewire::Core::Testing::Contracts

    def setup
      Julewire.reset!
    end
  end
end
