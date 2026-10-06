# frozen_string_literal: true

# Rails loads this file through the engine routes reloader while the
# application's route set is still open, which is why `draw` is correct here.
#
# Moving the mount into `after_initialize` with `append` fails SILENTLY: by then
# the route set is finalised, `append` blocks are never evaluated, and
# `/tickets` 404s on every direct visit, refresh or external link while in-app
# Ember transitions keep working perfectly. Nothing logs, nothing warns.
TicketingSystem::Engine.routes.draw do
  # JSON API, under /tickets/api.
  #
  # Declared BEFORE the page shell's `/:id` route so a numeric-looking path can
  # never be swallowed by the shell. `defaults: { format: :json }` means the
  # frontend can call `/tickets/api/tickets.json` and a bare `/tickets/api/tickets`
  # both resolve to the JSON action.
  #
  # These endpoints keep core's `check_xhr` and `verify_authenticity_token`
  # before_actions. Mutating actions deliberately do NOT skip CSRF verification:
  # `discourse/lib/ajax` sends the token in X-CSRF-Token, so legitimate calls
  # pass and a forged cross-site POST does not.
  scope "/api", defaults: { format: :json } do
    get "/meta" => "meta#show"
    get "/stats" => "stats#show"

    get "/tickets" => "tickets#index"
    post "/tickets" => "tickets#create"
    get "/tickets/:id" => "tickets#show"

    post "/tickets/:id/messages" => "messages#create"
    post "/tickets/:id/actions" => "actions#create"

    get "/departments" => "departments#index"
    post "/departments" => "departments#create"
    put "/departments/:id" => "departments#update"
    delete "/departments/:id" => "departments#destroy"
  end

  # Server-rendered shell. Ember only handles client-side transitions, so a
  # refresh on /tickets, /tickets/new or /tickets/12 is a real HTTP request that
  # would otherwise 404 before Ember ever boots. All of them render the same
  # shell; Ember replaces the body once it starts.
  #
  # `/admin` MUST be declared before `/:id`, and its existence is not optional:
  # the Ember route map declares `ticketing-system.admin` for the management page,
  # and the `:id` constraint below rejects "admin" — so without this line a hard
  # refresh on /tickets/admin 404s while in-app navigation to it works fine, which
  # is the most confusing possible split.
  #
  # The `:id` constraint keeps this route from shadowing anything else and makes
  # the intent explicit: only numeric ticket ids are page paths.
  get "/" => "pages#index"
  get "/new" => "pages#index"
  get "/admin" => "pages#index"
  get "/:id" => "pages#index", constraints: { id: /\d+/ }
end

Discourse::Application.routes.draw { mount ::TicketingSystem::Engine, at: "/tickets" }
