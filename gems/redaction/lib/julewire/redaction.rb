# frozen_string_literal: true

require "zeitwerk"
require "julewire/core"

module Julewire
  module Redaction
    # Header names may arrive as normalized symbols or literal HTTP spellings.
    AUTH_FILTERS = %i[
      access_token
      refresh_token
      id_token
      client_secret
      assertion
      code_verifier
      token
      authorization
      cookie
      set_cookie
      x_api_key
      set-cookie
      x-api-key
    ].freeze

    COMMON_FILTERS = %i[
      api_key
      password
      passwd
      private_key
      secret
    ].freeze

    SECRET_FILTERS = (AUTH_FILTERS + COMMON_FILTERS + %i[
      crypt
      salt
      certificate
      otp
      cvv
      cvc
    ]).uniq.freeze

    PII_FILTERS = %i[
      email
      ssn
    ].freeze

    DEFAULT_FILTERS = (SECRET_FILTERS + PII_FILTERS).uniq.freeze
    DEFAULT_MASK = "[FILTERED]"

    PathFilter = Data.define(:filter)

    class << self
      def path(filter)
        PathFilter.new(filter)
      end
    end

    extend Core::Integration::Configurable

    configurable_with { Configuration }
  end

  loader = Zeitwerk::Loader.for_gem_extension(self)
  loader.setup
  Core::Processing.register(:redaction) { |*args, **options| Redaction::Processor.new(*args, **options) }
end
