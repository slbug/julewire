# frozen_string_literal: true

require "julewire/core/testing/coverage"
Julewire::Core::Testing::Coverage.start!

require "julewire/gcp"
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
    end
  end
end
