# frozen_string_literal: true

require "test_helper"
require "generators/julewire/install_generator"
require "rails/generators/test_case"
require "tmpdir"

module Julewire
  class TestRailsInstallGenerator < ::Rails::Generators::TestCase
    cover Julewire::Generators::InstallGenerator
    tests Julewire::Generators::InstallGenerator
    setup :prepare_temp_destination
    setup :prepare_destination

    def test_generator_creates_initializer
      run_generator

      assert_file "config/initializers/julewire.rb" do |content|
        expected = <<~RUBY
          # frozen_string_literal: true

          Julewire.configure do |config|
            config.destinations.use(:default, output: $stdout) if config.destinations.empty?

            config.processors.prepend(
              :rails_parameter_filter,
              Rails.application.config.filter_parameters
            )
          end

          Julewire::Rails.configure do |config|
            config.request_summary = true
            config.structured_events = true
            config.error_reports = true
          end
        RUBY

        assert_equal expected, content
        assert_instance_of RubyVM::InstructionSequence, RubyVM::InstructionSequence.compile(content)
      end
    end

    private

    def prepare_temp_destination
      self.destination_root = Dir.mktmpdir("julewire-rails-generator-")
    end
  end
end
