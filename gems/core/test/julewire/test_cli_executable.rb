# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"

module Julewire
  class TestCLIExecutable < Minitest::Test
    # Mutant kills the parent test process with SIGKILL on timeout; it cannot
    # reliably reap this test's child Ruby process.
    cover "ExternalProcessBoundary"

    def test_executable_prints_version
      stdout, stderr, status = Open3.capture3(
        { "RUBYLIB" => core_lib_path },
        RbConfig.ruby,
        core_executable_path,
        "--version"
      )

      assert_predicate status, :success?
      assert_empty stderr
      assert_equal "julewire #{Core::VERSION}\n", stdout
    end

    private

    def core_executable_path = File.expand_path("../../exe/julewire", __dir__)

    def core_lib_path = File.expand_path("../../lib", __dir__)
  end
end
