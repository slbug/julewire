# frozen_string_literal: true

require "julewire/core/testing/coverage"
Julewire::Core::Testing::Coverage.start!

require "julewire/redaction"
require "julewire/core/testing"

require "minitest/autorun"
require "mutant/minitest/coverage"
require "json"
require "stringio"

module Minitest
  class Test
    include Julewire::Core::Testing::Contracts

    def setup
      Julewire.reset!
      Julewire::Redaction.reset!
    end
  end
end
