# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestKarafkaPublicApi < Minitest::Test
    cover Julewire::Karafka::Configuration
    cover Julewire::Karafka::ForkHooks
    cover Julewire::Karafka::Installer
    cover "Julewire::Karafka::Installer.install!"
    cover Julewire::Karafka::Error
    cover "Julewire::Karafka.install!"
    include JulewireCapture

    FakeMonitor = KarafkaTestSupport::FakeMonitor
    FakeMonitorWithDangerousListeners = KarafkaTestSupport::FakeMonitorWithDangerousListeners
    EventFlakyMonitor = KarafkaTestSupport::EventFlakyMonitor
    FakeEvent = KarafkaTestSupport::FakeEvent

    def setup
      super
      reset_julewire!
    end

    def test_configure_and_public_install_helpers
      monitor = FakeMonitor.new
      Julewire::Karafka.configure { it.consumer_event_names = %w[custom.event] }

      Julewire::Karafka.install!(monitor: monitor)

      assert_includes monitor.subscriptions, "custom.event"
      assert_includes monitor.subscriptions, "swarm.node.after_fork"
    ensure
      Julewire::Karafka.reset!
    end

    def test_install_helper_subscribes_consumer_monitor
      monitor = FakeMonitor.new

      assert_same monitor, Julewire::Karafka.install!(monitor: monitor)

      assert_includes monitor.subscriptions, "consumer.consumed"
      assert_includes monitor.subscriptions, "swarm.node.after_fork"
    end

    def test_install_helper_can_use_app_monitor
      monitor = FakeMonitor.new
      app = fake_karafka_app(monitor)

      assert_same monitor, Julewire::Karafka.install!(app: app)

      assert_includes monitor.subscriptions, "consumer.consumed"
    end

    def test_install_helper_can_skip_consumer_and_producer
      assert_nil Julewire::Karafka.install!(consumer: false)
      assert_nil Julewire::Karafka.install!(consumer: false, producer: false)
    end

    def test_configure_requires_block
      error = assert_raises(ArgumentError) { Julewire::Karafka.configure }

      assert_equal "Julewire::Karafka.configure requires a block", error.message
    end

    def test_config_can_be_assigned_and_reset
      configuration = Julewire::Karafka::Configuration.new
      configuration.source = "assigned"

      Julewire::Karafka.config = configuration

      assert_same configuration, Julewire::Karafka.config

      Julewire::Karafka.reset!

      refute_same configuration, Julewire::Karafka.config
      assert_equal "karafka", Julewire::Karafka.config.source
    end

    def test_installer_does_not_scan_existing_monitor_listeners
      monitor = FakeMonitorWithDangerousListeners.new

      Julewire::Karafka.install!(monitor: monitor)

      assert_includes monitor.subscriptions, "consumer.consumed"
    end

    def test_installer_subscribes_fork_hooks_when_consumer_events_are_disabled
      configuration = Julewire::Karafka::Configuration.new
      configuration.consumer_events = false
      monitor = FakeMonitor.new

      Julewire::Karafka.install!(monitor: monitor, configuration: configuration)

      assert_includes monitor.subscriptions, "swarm.node.after_fork"
      refute_includes monitor.subscriptions, "consumer.consumed"
    end

    def test_fork_hook_resets_julewire_process_state
      records = capture_records
      monitor = FakeMonitor.new

      Julewire::Karafka::ForkHooks.subscribe!(monitor, configuration: Julewire::Karafka::Configuration.new)
      Julewire.emit(message: "before fork")

      assert_operator Julewire.health.dig(:pipeline, :counts, :entered), :>, 0

      monitor.publish("swarm.node.after_fork")

      assert_equal 0, Julewire.health.dig(:pipeline, :counts, :entered)
      assert_equal "before fork", records.fetch(0).fetch(:message)
    end

    def test_fork_hooks_respect_disabled_and_missing_subscribe
      configuration = Julewire::Karafka::Configuration.new
      configuration.enabled = false
      monitor = FakeMonitor.new

      assert_nil Julewire::Karafka::ForkHooks.subscribe!(monitor, configuration: configuration)
      assert_empty monitor.subscriptions
      assert_nil Julewire::Karafka::ForkHooks.subscribe!(Object.new, configuration: Julewire::Karafka::Configuration.new)
    end

    def test_fork_hooks_subscribe_idempotently
      monitor = FakeMonitor.new
      configuration = Julewire::Karafka::Configuration.new

      assert_same monitor, Julewire::Karafka::ForkHooks.subscribe!(monitor, configuration: configuration)
      assert_same monitor, Julewire::Karafka::ForkHooks.subscribe!(monitor, configuration: configuration)

      assert_equal %w[swarm.node.after_fork swarm.manager.after_fork], monitor.subscriptions
    end

    def test_fork_hooks_retry_missing_events_from_partial_state
      monitor = FakeMonitor.new
      state = Julewire::Karafka::ForkHooks.const_get(:INSTALL_STATE, false)
      state.store(monitor, { events: ["swarm.node.after_fork"] })

      Julewire::Karafka::ForkHooks.subscribe!(monitor, configuration: Julewire::Karafka::Configuration.new)

      assert_equal %w[swarm.manager.after_fork], monitor.subscriptions
    end

    def test_fork_hooks_record_subscribe_failure_metadata
      monitor = EventFlakyMonitor.new(ArgumentError.new("bad subscribe"), fail_events: %w[swarm.node.after_fork])

      Julewire::Karafka::ForkHooks.subscribe!(monitor, configuration: Julewire::Karafka::Configuration.new)

      failure = Julewire.health.dig(:process_integrations, :karafka, :last_failure)

      assert_equal %w[swarm.manager.after_fork], monitor.subscriptions
      assert_equal :subscribe, failure.fetch(:action)
      assert_equal :fork_hooks, failure.fetch(:component)
      assert_equal "swarm.node.after_fork", failure.fetch(:event)
    end

    def test_fork_hooks_record_after_fork_failure_metadata
      Julewire.stubs(:after_fork!).raises(RuntimeError, "reset failed")

      Julewire::Karafka::ForkHooks.handle("swarm.node.after_fork", FakeEvent.new)

      failure = Julewire.health.dig(:process_integrations, :karafka, :last_failure)

      assert_equal :after_fork, failure.fetch(:action)
      assert_equal :fork_hooks, failure.fetch(:component)
      assert_equal "swarm.node.after_fork", failure.fetch(:event)
    end

    def test_installers_handle_disabled_and_missing_monitors
      configuration = Julewire::Karafka::Configuration.new
      configuration.enabled = false

      assert_false Julewire::Karafka.install!(monitor: FakeMonitor.new, configuration: configuration)

      error = assert_raises(Julewire::Karafka::Error) { Julewire::Karafka.install!(app: Object.new) }
      assert_match "Karafka monitor", error.message
    end
  end
end
