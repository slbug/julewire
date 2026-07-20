# frozen_string_literal: true

require "mutant/minitest/coverage"

if ENV["JULEWIRE_MUTANT_COVER_ALL"] == "1"
  cover_all = Object.const_get(:Set).new(["Julewire*"]).freeze
  coverage = Object.const_get(:Mutant).const_get(:Minitest).const_get(:Coverage)

  coverage.define_method(:resolve_cover_expressions) { cover_all }
end
