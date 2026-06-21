# frozen_string_literal: true

require "test_helper"
require "generators/julewire/install_generator"
require "rails/generators/test_case"

module Julewire
  class TestRailsInstallGenerator < ::Rails::Generators::TestCase
    tests Julewire::Generators::InstallGenerator
    destination File.expand_path("../tmp/generator", __dir__)
    setup :prepare_destination

    def test_generator_creates_initializer
      run_generator

      assert_file "config/initializers/julewire.rb" do |content|
        assert_includes content, "Julewire.configure"
        assert_includes content, ":rails_parameter_filter"
        assert_includes content, "Julewire::Rails.configure"
      end
    end
  end
end
