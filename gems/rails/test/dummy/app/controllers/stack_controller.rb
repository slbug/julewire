# frozen_string_literal: true

class StackController < ApplicationController
  class RescuedError < StandardError; end

  rescue_from RescuedError, with: :render_rescued_error

  def html
    Rails.logger.info("controller explicit logger")
    Widget.create!(name: "html")
    @count = Widget.count
    render inline: "<%= @count %>", formats: [:html]
  end

  def json
    Rails.logger.debug("json explicit logger")
    Widget.count
    render json: { ok: true, count: Widget.count }
  end

  def binary
    send_data "binary-body", type: "application/octet-stream", disposition: "inline"
  end

  def echo
    render json: { body: request.raw_post }
  end

  def event_context
    Rails.event.notify("stack.context_probe", action: "event_context")
    Rails.error.report(RuntimeError.new("reported"), handled: true, context: { section: "stack" })
    render json: { ok: true }
  end

  def error
    raise "stack boom"
  end

  def rescued_error
    raise RescuedError, "stack rescued"
  end

  private

  def render_rescued_error
    render json: { rescued: true }
  end
end
