# frozen_string_literal: true

require "julewire/core/testing/coverage"
Julewire::Core::Testing::Coverage.start!

require "julewire/rack"
require "minitest/autorun"
require "mutant/minitest/coverage"
