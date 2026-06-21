# frozen_string_literal: true

module Julewire
  module ActiveJobFixtures
    class FakeJob
      attr_reader :job_id, :provider_job_id, :queue_name, :priority, :executions, :enqueued_at, :scheduled_at

      def initialize
        @job_id = "job-1"
        @provider_job_id = "provider-1"
        @queue_name = "default"
        @priority = 10
        @executions = 1
        @enqueued_at = Time.utc(2026, 1, 1)
        @scheduled_at = nil
      end

      def serialize
        { "job_id" => job_id }
      end

      def deserialize(_job_data)
        nil
      end
    end

    class RaisingJob
      class << self
        def name = "RaisingJob"
      end

      def job_id = "job-error"

      def provider_job_id = raise("provider unavailable")

      def queue_name = nil

      def priority = nil

      def executions = nil

      def enqueued_at = "already serialized"

      def scheduled_at = nil
    end

    class FakeReporter
      attr_reader :subscriptions, :unsubscriptions

      def initialize
        @subscriptions = []
        @unsubscriptions = []
      end

      def subscribe(subscriber, &block)
        @subscriptions << [subscriber, block]
      end

      def unsubscribe(subscriber)
        @unsubscriptions << subscriber
      end
    end

    class FakeSummary
      def add(_fields)
        raise "summary failed"
      end
    end

    class FakeBase
      class << self
        attr_reader :callbacks

        def inherited_modules
          @inherited_modules ||= []
        end

        def <(other) = inherited_modules.include?(other)

        def prepend(mod)
          inherited_modules << mod
        end

        def around_perform(&block)
          (@callbacks ||= []) << block
        end
      end
    end

    class FakeSerializedJob
      prepend Julewire::ActiveJob::JobSerialization

      def serialize
        {}
      end

      def deserialize(_job_data)
        nil
      end
    end

    class SerializationBase
      class << self
        def around_perform(&)
          nil
        end
      end

      def serialize
        {}
      end

      def deserialize(_job_data)
        nil
      end
    end
  end
end
