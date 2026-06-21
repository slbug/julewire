# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestKarafkaPublicApi < Minitest::Test
    include JulewireCapture

    FakeMonitor = KarafkaTestSupport::FakeMonitor
    FakeMonitorWithDangerousListeners = KarafkaTestSupport::FakeMonitorWithDangerousListeners

    def setup
      super
      reset_julewire!
    end

    def test_that_it_has_a_version_number
      refute_nil ::Julewire::Karafka::VERSION
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

      Julewire::Karafka.install!(monitor: monitor)

      assert_includes monitor.subscriptions, "consumer.consumed"
      assert_includes monitor.subscriptions, "swarm.node.after_fork"
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

      Julewire::Karafka::ForkHooks.subscribe!(monitor)
      Julewire.emit(message: "before fork")

      assert_operator Julewire.health.dig(:pipeline, :counts, :entered), :>, 0

      monitor.publish("swarm.node.after_fork")

      assert_equal 0, Julewire.health.dig(:pipeline, :counts, :entered)
      assert_equal "before fork", records.fetch(0).fetch(:message)
    end

    def test_installers_handle_disabled_and_missing_monitors
      configuration = Julewire::Karafka::Configuration.new
      configuration.enabled = false

      refute Julewire::Karafka.install!(monitor: FakeMonitor.new, configuration: configuration)

      error = assert_raises(Julewire::Karafka::Error) { Julewire::Karafka.install!(app: Object.new) }
      assert_match "Karafka monitor", error.message
    end
  end
end
