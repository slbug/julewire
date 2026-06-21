# frozen_string_literal: true

module Julewire
  module Rails
    class RequestFields
      REMOTE_IP_ENV_KEY = "julewire.rails.remote_ip"

      def initialize(request)
        @request = request
      end

      def id
        value = @request.request_id if @request.respond_to?(:request_id)
        value || header("action_dispatch.request_id") || header("HTTP_X_REQUEST_ID")
      rescue StandardError
        nil
      end

      def method
        @request.request_method
      end

      def path
        @request.path
      end

      def filtered_path
        @request.filtered_path
      end

      def filtered_url
        "#{@request.protocol}#{@request.host_with_port}#{filtered_path}"
      rescue StandardError
        nil
      end

      def user_agent
        header("HTTP_USER_AGENT")
      end

      def remote_ip
        env = @request.env if @request.respond_to?(:env)
        return env[REMOTE_IP_ENV_KEY] if env&.key?(REMOTE_IP_ENV_KEY)

        value = @request.remote_ip
        env[REMOTE_IP_ENV_KEY] = value if env
        value
      rescue StandardError
        nil
      end

      private

      def header(key)
        @request.get_header(key)
      rescue StandardError
        nil
      end
    end
  end
end
