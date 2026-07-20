# frozen_string_literal: true

require "open3"
require "rbconfig"
require "support/active_job_test_support"

module Julewire
  class TestActiveJobInstallerAndRailtie < Minitest::Test
    cover Julewire::ActiveJob::Installer
    cover "Julewire::ActiveJob::Railtie*"
    cover Julewire::ActiveJob::JobSerialization
    cover Julewire::ActiveJob::LogSubscriberSilencer
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

    def test_installer_active_job_base_requires_active_job_base
      calls = []

      with_overridden_singleton_method(
        Julewire::ActiveJob::Installer,
        :require,
        proc { |path|
          calls << path
          Kernel.require(path)
        }
      ) do
        assert_equal ::ActiveJob::Base, Julewire::ActiveJob::Installer.send(:active_job_base)
      end

      assert_equal ["active_job/base"], calls
    end

    def test_railtie_installs_active_job_hook
      loads = []
      base = Class.new(FakeBase)
      settings = Julewire::ActiveJob::Railtie.config.julewire_active_job
      app = Struct.new(:config).new(Struct.new(:julewire_active_job).new(settings))
      initializer = Julewire::ActiveJob::Railtie.initializers.find { it.name == "julewire.active_job" }

      with_overridden_singleton_method(::ActiveSupport, :on_load, proc { |name, &block|
        loads << name
        base.instance_exec(&block)
      }) do
        initializer.run(app)
      end

      assert_equal [:active_job], loads
      assert_includes base.inherited_modules, Julewire::ActiveJob::JobSerialization
      assert_equal 1, base.callbacks.length
    end

    def test_entrypoint_loads_railtie_when_rails_railtie_exists
      railtie = Julewire::ActiveJob::Railtie

      assert_same Julewire::ActiveJob::Railtie, railtie
      assert_operator railtie, :<, ::Rails::Railtie
    end

    def test_railtie_skip_install_when_disabled
      settings = Julewire::ActiveJob::Configuration.new
      settings.enabled = false

      with_overridden_singleton_method(::ActiveSupport, :on_load, proc { flunk "should not install" }) do
        assert_nil Julewire::ActiveJob::Railtie.install_active_job!(settings)
      end
    end

    def test_railtie_installs_when_enabled
      base = Class.new(FakeBase)
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
      assert_same settings, base.julewire_active_job_configuration
    end

    def test_installer_can_skip_execution_events_and_silencing
      configuration = Julewire::ActiveJob::Configuration.new
      configuration.execution = false
      configuration.structured_events = false
      configuration.silence_log_subscriber = false

      base = Class.new(FakeBase)
      with_overridden_singleton_method(Julewire::ActiveJob::LogSubscriberSilencer, :silence!, proc {
        flunk "should not silence"
      }) do
        installed = Julewire::ActiveJob::Installer.install!(base: base, configuration: configuration)

        assert_same base, installed
      end

      assert_same configuration, Julewire::ActiveJob.config
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

      assert_same configuration, base.julewire_active_job_configuration
    end

    def test_installer_configuration_method_is_inherited_by_job_subclasses
      configuration = Julewire::ActiveJob::Configuration.new
      configuration.execution = false
      configuration.structured_events = false
      configuration.silence_log_subscriber = false
      base = Class.new(FakeBase)

      Julewire::ActiveJob::Installer.install!(base: base, configuration: configuration)

      assert_same configuration, Class.new(base).julewire_active_job_configuration
    end

    def test_installer_can_replace_inherited_configuration_method_on_subclass
      configuration = Julewire::ActiveJob::Configuration.new
      configuration.execution = false
      configuration.structured_events = false
      configuration.silence_log_subscriber = false
      next_configuration = Julewire::ActiveJob::Configuration.new
      next_configuration.execution = false
      next_configuration.structured_events = false
      next_configuration.silence_log_subscriber = false
      base = Class.new(FakeBase)
      child = Class.new(base)

      Julewire::ActiveJob::Installer.install!(base: base, configuration: configuration)
      Julewire::ActiveJob::Installer.install!(base: child, configuration: next_configuration)

      assert_same configuration, base.julewire_active_job_configuration
      assert_same next_configuration, child.julewire_active_job_configuration
    end

    def test_installer_replaces_configuration_method_without_warning
      configuration = Julewire::ActiveJob::Configuration.new
      configuration.execution = false
      configuration.structured_events = false
      configuration.silence_log_subscriber = false
      next_configuration = Julewire::ActiveJob::Configuration.new
      next_configuration.execution = false
      next_configuration.structured_events = false
      next_configuration.silence_log_subscriber = false
      base = Class.new(FakeBase)

      previous_verbose = $VERBOSE
      $VERBOSE = true
      _stdout, stderr = capture_io do
        Julewire::ActiveJob::Installer.install!(base: base, configuration: configuration)
        Julewire::ActiveJob::Installer.install!(base: base, configuration: next_configuration)
      end

      assert_empty stderr
      assert_same next_configuration, base.julewire_active_job_configuration
    ensure
      $VERBOSE = previous_verbose if defined?(previous_verbose)
    end

    def test_installer_default_configuration_installs_enabled_base
      base = Class.new(FakeBase)

      with_overridden_singleton_method(Julewire::ActiveJob::LogSubscriberSilencer, :silence!, proc {}) do
        installed = Julewire::ActiveJob::Installer.install!(base: base)

        assert_same base, installed
      end

      assert_instance_of Julewire::ActiveJob::Configuration, Julewire::ActiveJob.config
      assert_includes base.inherited_modules, Julewire::ActiveJob::JobSerialization
      assert_equal 1, base.callbacks.length
    ensure
      Julewire::ActiveJob::Subscribers::Event.reset!
      Julewire::ActiveJob.reset!
    end

    def test_installer_installed_execution_callback_uses_initial_configuration_and_job
      configuration = Julewire::ActiveJob::Configuration.new
      configuration.summary_event = "initial.completed"
      configuration.structured_events = false
      configuration.silence_log_subscriber = false
      base = Class.new(FakeBase)

      Julewire::ActiveJob::Installer.install!(base: base, configuration: configuration)

      records = capture_records
      base.callbacks.fetch(0).call(fake_job, -> { "ok" })
      summary = records.find { it[:kind] == :summary }

      assert_equal "initial.completed", summary.fetch(:event)
      assert_equal "Julewire::ActiveJobFixtures::FakeJob", active_job_attributes(summary).fetch(:job_class)
      assert_equal "job-1", active_job_attributes(summary).fetch(:job_id)
    end

    def test_installer_updates_existing_execution_callback_without_stacking
      configuration = Julewire::ActiveJob::Configuration.new
      configuration.structured_events = false
      configuration.silence_log_subscriber = false
      next_configuration = Julewire::ActiveJob::Configuration.new
      next_configuration.summary_event = "next.completed"
      next_configuration.structured_events = false
      next_configuration.silence_log_subscriber = false
      base = Class.new(FakeBase)

      Julewire::ActiveJob::Installer.install!(base: base, configuration: configuration)
      Julewire::ActiveJob::Installer.install!(base: base, configuration: next_configuration)

      assert_equal 1, base.callbacks.length

      records = capture_records
      base.callbacks.fetch(0).call(fake_job, -> { "ok" })

      summary = records.find { it[:kind] == :summary }

      assert_equal "next.completed", summary.fetch(:event)
      assert_equal "Julewire::ActiveJobFixtures::FakeJob", active_job_attributes(summary).fetch(:job_class)
      assert_equal "job-1", active_job_attributes(summary).fetch(:job_id)
    end

    def test_installer_silences_log_subscriber_when_enabled
      configuration = Julewire::ActiveJob::Configuration.new
      configuration.execution = false
      configuration.structured_events = false
      called = false

      with_overridden_singleton_method(Julewire::ActiveJob::LogSubscriberSilencer, :silence!, proc { called = true }) do
        Julewire::ActiveJob::Installer.install!(base: Class.new(FakeBase), configuration: configuration)
      end

      assert_true called
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

      assert_true subscriber.accept?(name: "custom.event")
      assert_false subscriber.accept?(name: "active_job.perform")
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

  class TestActiveJobEntrypointProcessBoundary < Minitest::Test
    # Mutant kills the parent test process with SIGKILL on timeout; it cannot
    # reliably reap this test's child Ruby process.
    cover "ExternalProcessBoundary"

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
  end
end
