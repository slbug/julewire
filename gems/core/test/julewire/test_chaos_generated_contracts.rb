# frozen_string_literal: true

require "test_helper"
require "julewire/core/testing"

module Julewire
  class TestChaosGeneratedContracts < Minitest::Test
    cover Julewire::Core::Testing::Chaos
    cover Julewire::Core::Testing::Chaos::Catalog

    def test_catalog_contract_handles_fixed_seed_generated_component_matrix
      random = Random.new(20_260_620)
      kinds = %i[processor formatter encoder destination subscriber listener]
      errors = [RuntimeError.new("runtime"), ArgumentError.new("argument")]
      events = []
      expected = []

      5.times do |case_index|
        selected = kinds.shuffle(random: random).take(random.rand(2..kinds.size))
        catalog = generated_catalog(case_index, selected, errors, events, expected)

        assert_nil Julewire::Testing::Chaos.assert_discovered_chaos_contracts(self, catalog: catalog, errors: errors)
      end

      assert_equal expected, events
    end

    private

    def generated_catalog(case_index, selected, errors, events, expected)
      Julewire::Testing::Chaos.catalog do |components|
        selected.each_with_index do |kind, entry_index|
          name = :"#{kind}_#{case_index}_#{entry_index}"
          expected.concat(errors.map { [case_index, kind, name, it.class] })
          components.public_send(kind, name) do |failure|
            events << [case_index, kind, name, failure.class]
          end
        end
      end
    end
  end
end
