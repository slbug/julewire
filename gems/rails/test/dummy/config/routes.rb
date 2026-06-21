# frozen_string_literal: true

Rails.application.routes.draw do
  get "/stack/html", to: "stack#html"
  get "/stack/json", to: "stack#json"
  get "/stack/binary", to: "stack#binary"
  get "/stack/event_context", to: "stack#event_context"
  get "/stack/error", to: "stack#error"
  get "/stack/rescued_error", to: "stack#rescued_error"
  post "/stack/echo", to: "stack#echo"
end
