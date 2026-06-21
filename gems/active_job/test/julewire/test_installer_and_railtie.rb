# frozen_string_literal: true

require "open3"
require "rbconfig"
require "support/active_job_test_support"

module Julewire
  class TestActiveJobInstallerAndRailtie < Minitest::Test
    include ActiveJobTestSupport

    def test_installer_respects_disabled_configuration
      configuration = Julewire::ActiveJob::Configuration.new
      configuration.enabled = false

      assert_nil Julewire::ActiveJob::Installer.install!(base: FakeBase, configuration: configuration)
    end

    def test_installer_requires_active_job_base
      with_overridden_singleton_method(
        Julewire::ActiveJob::Installer,
        :active_job_base,
        proc {}
      ) do
        error = assert_raises(Julewire::ActiveJob::Error) do
          Julewire::ActiveJob::Installer.install!(base: nil, configuration: Julewire::ActiveJob::Configuration.new)
        end

        assert_match "ActiveJob::Base", error.message
      end
    end

    def test_installer_finds_loaded_active_job_base
      require "active_support"
      require "active_job"
      configuration = Julewire::ActiveJob::Configuration.new
      configuration.execution = false
      configuration.structured_events = false
      configuration.silence_log_subscriber = false

      assert_equal ::ActiveJob::Base, Julewire::ActiveJob::Installer.install!(configuration: configuration)
    end

    def test_railtie_installs_active_job_hook
      with_fake_rails_railtie do |loads, base|
        load File.expand_path("../../lib/julewire/active_job/railtie.rb", __dir__)
        settings = Julewire::ActiveJob::Railtie.config.julewire_active_job
        app = Struct.new(:config).new(Struct.new(:julewire_active_job).new(settings))

        with_overridden_singleton_method(::ActiveSupport, :on_load, proc { |name, &block|
          loads << name
          base.instance_exec(&block)
        }) do
          Julewire::ActiveJob::Railtie.initializers.fetch(0).call(app)
        end

        assert_equal [:active_job], loads
        assert_includes base.inherited_modules, Julewire::ActiveJob::JobSerialization
        assert_equal 1, base.callbacks.length
      end
    end

    def test_entrypoint_loads_railtie_when_rails_railtie_exists
      with_fake_rails_railtie do
        Julewire::ActiveJob.autoload(:Railtie, File.expand_path("../../lib/julewire/active_job/railtie.rb", __dir__))

        Julewire::ActiveJob.load_railtie_if_rails!

        assert_operator Julewire::ActiveJob::Railtie, :<, ::Rails::Railtie
      end
    end

    def test_entrypoint_eager_load_skips_railtie_without_rails
      root = File.expand_path("../..", __dir__)
      load_paths = [
        File.join(root, "lib"),
        File.expand_path("../core/lib", root),
        ENV.fetch("RUBYLIB", nil)
      ].compact.join(File::PATH_SEPARATOR)
      stdout, stderr, status = Open3.capture3(
        { "RUBYLIB" => load_paths },
        RbConfig.ruby,
        "-rbundler/setup",
        "-e",
        'require "julewire/active_job"; Zeitwerk::Loader.eager_load_all; print "ok"',
        chdir: root
      )

      assert_predicate status, :success?, stderr
      assert_equal "ok", stdout
    end

    def test_railtie_skip_install_when_disabled
      with_fake_rails_railtie do
        load File.expand_path("../../lib/julewire/active_job/railtie.rb", __dir__)
        settings = Julewire::ActiveJob::Configuration.new
        settings.enabled = false

        with_overridden_singleton_method(::ActiveSupport, :on_load, proc { flunk "should not install" }) do
          assert_nil Julewire::ActiveJob::Railtie.install_active_job!(settings)
        end
      end
    end

    def test_railtie_installs_when_enabled
      with_fake_rails_railtie do |_loads, base|
        load File.expand_path("../../lib/julewire/active_job/railtie.rb", __dir__)
        settings = Julewire::ActiveJob::Configuration.new
        loaded = []

        with_overridden_singleton_method(::ActiveSupport, :on_load, proc { |name, &block|
          loaded << name
          base.instance_exec(&block)
        }) do
          Julewire::ActiveJob::Railtie.install_active_job!(settings)
        end

        assert_equal [:active_job], loaded
        assert_includes base.inherited_modules, Julewire::ActiveJob::JobSerialization
      end
    end

    def test_installer_can_skip_execution_events_and_silencing
      configuration = Julewire::ActiveJob::Configuration.new
      configuration.execution = false
      configuration.structured_events = false
      configuration.silence_log_subscriber = false

      base = Class.new(FakeBase)
      installed = Julewire::ActiveJob::Installer.install!(base: base, configuration: configuration)

      assert_same base, installed
      assert_empty base.callbacks || []
    end

    def test_installer_stores_configuration_on_base_without_class_attribute
      configuration = Julewire::ActiveJob::Configuration.new
      configuration.execution = false
      configuration.structured_events = false
      configuration.silence_log_subscriber = false
      inherited_modules = []
      base = Object.new
      base.define_singleton_method(:<) { inherited_modules.include?(it) }
      base.define_singleton_method(:prepend) { inherited_modules << it }

      Julewire::ActiveJob::Installer.install!(base: base, configuration: configuration)

      assert_same configuration, base.instance_variable_get(:@julewire_active_job_configuration)
    end

    def test_installer_installs_structured_event_subscriber_once
      configuration = Julewire::ActiveJob::Configuration.new
      configuration.silence_log_subscriber = false
      next_configuration = Julewire::ActiveJob::Configuration.new
      next_configuration.event_prefixes = ["custom."]
      next_configuration.silence_log_subscriber = false
      reporter = FakeReporter.new

      base = Class.new(FakeBase)
      Julewire::ActiveJob::Subscribers::Event.reset!
      with_overridden_singleton_method(
        Julewire::Core::Integration::Lifecycle,
        :require_optional,
        proc { |*| }
      ) do
        Julewire::ActiveJob::Installer.install!(base: base, event_reporter: reporter, configuration: configuration)
        Julewire::ActiveJob::Installer.install!(base: base, event_reporter: reporter, configuration: next_configuration)
      end

      assert_equal 1, reporter.subscriptions.length
      refute_empty base.callbacks
      subscriber = reporter.subscriptions.fetch(0).fetch(0)

      assert subscriber.accept?(name: "custom.event")
      refute subscriber.accept?(name: "active_job.perform")
    ensure
      Julewire::ActiveJob::Subscribers::Event.reset!
    end

    def test_installer_unsubscribes_structured_event_subscriber_when_disabled
      configuration = Julewire::ActiveJob::Configuration.new
      configuration.silence_log_subscriber = false
      disabled_configuration = Julewire::ActiveJob::Configuration.new
      disabled_configuration.structured_events = false
      disabled_configuration.silence_log_subscriber = false
      reporter = FakeReporter.new
      base = Class.new(FakeBase)

      Julewire::ActiveJob::Subscribers::Event.reset!
      with_overridden_singleton_method(Julewire::Core::Integration::Lifecycle, :require_optional, proc { |*| }) do
        Julewire::ActiveJob::Installer.install!(base: base, event_reporter: reporter, configuration: configuration)
      end
      subscriber = reporter.subscriptions.fetch(0).fetch(0)
      Julewire::ActiveJob::Installer.install!(base: base, event_reporter: reporter,
                                              configuration: disabled_configuration)

      refute_predicate Julewire::ActiveJob::Subscribers::Event, :installed?
      assert_equal [subscriber], reporter.unsubscriptions
    ensure
      Julewire::ActiveJob::Subscribers::Event.reset!
    end

    def test_active_job_default_event_reporter_uses_rails_event
      event = Object.new

      with_fake_rails_event(event) do
        assert_same event, Julewire::RailsSupport::EventReporter.default
      end
    end
  end
end
