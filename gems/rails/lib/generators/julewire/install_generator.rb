# frozen_string_literal: true

require "rails/generators"

module Julewire
  module Generators
    class InstallGenerator < ::Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      def copy_initializer
        template "julewire.rb", "config/initializers/julewire.rb"
      end
    end
  end
end
