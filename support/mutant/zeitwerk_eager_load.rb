# frozen_string_literal: true

hooks.register(:env_infection_post) do
  Zeitwerk::Loader.eager_load_all if defined?(Zeitwerk::Loader)
end
