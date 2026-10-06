# frozen_string_literal: true

module ::TicketingSystem
  # Server-rendered shell for /tickets, /tickets/new and /tickets/:id.
  #
  # It exists so a direct visit, a refresh or a crawler gets real HTML instead of
  # a 404 — Ember only handles client-side transitions. The markup lands inside a
  # <noscript> block (see app/views/layouts/application.html.erb), so it is
  # invisible to JS-enabled visitors and free in the common case, which is exactly
  # why it should carry real content rather than a placeholder.
  #
  # Deliberately NO `raise Discourse::NotFound unless request.format.html?`.
  # That reads like harmless defensive code and breaks the route: Discourse issues
  # JSON-accepting preload XHRs for page routes, the format test fails, and the
  # page 404s on a URL whose route matched perfectly. `skip_before_action
  # :check_xhr` is Discourse's own mechanism for opting a page route back in.
  class PagesController < BaseController
    skip_before_action :check_xhr, only: :index

    SHELL_LIMIT = 20

    def index
      @page_title = I18n.t("ticketing_system.page.title")
      @tickets = shell_tickets
      @ticket_count = @tickets.size
      @plugin_version = ::TicketingSystem::VERSION

      # The ticket in the URL, when there is one. `params[:id]` is only populated
      # for the `/tickets/:id` form of the shell.
      @ticket = nil
      if params[:id].present?
        @ticket = Ticket.includes(:department, :requester, :assignee).find_by(id: params[:id])
        @ticket = nil unless @ticket && Permissions.can_view?(current_user, @ticket, staff: staff?)
      end

      render :index
    end

    private

    # What a no-JS visitor or a crawler should see: their own tickets, or the
    # active queue for staff. Never internal notes, never another user's tickets.
    def shell_tickets
      scope = Ticket.includes(:department, :assignee).recent.limit(SHELL_LIMIT)
      scope = staff? ? scope.active : scope.for_requester(current_user)
      scope.to_a
    end
  end
end
