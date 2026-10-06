# frozen_string_literal: true

module ::TicketingSystem
  # The state-change endpoint: status, priority, assignment, department.
  #
  # One action rather than four, because the frontend's action bar posts the same
  # shape for all of them and four near-identical actions would be four places to
  # keep the permission check and the response envelope in sync.
  #
  # The discriminator is `params[:operation]`, NOT `params[:action]` — Rails
  # reserves `action` and `controller` in the params hash for routing, and
  # reading them produces the name of this method rather than the caller's intent.
  class ActionsController < BaseController
    OPERATIONS = %w[status priority assign department].freeze

    def create
      ticket = find_ticket!(params[:id])
      operation = params[:operation].to_s

      unless OPERATIONS.include?(operation)
        raise Errors::Invalid.new(:invalid_operation, http_status: 400, operation: operation)
      end

      case operation
      when "status"
        TicketUpdater.change_status!(ticket: ticket, actor: current_user, status: params[:status])
      when "priority"
        TicketUpdater.change_priority!(ticket: ticket, actor: current_user, priority: params[:priority])
      when "assign"
        # `assignee` accepts nil, "none", "me", a username or a user id; the
        # updater resolves all of them so the client never needs to know its own
        # id.
        TicketUpdater.assign!(ticket: ticket, actor: current_user, assignee: params[:assignee])
      when "department"
        TicketUpdater.change_department!(
          ticket: ticket,
          actor: current_user,
          department: params[:department].presence || params[:department_id],
        )
      end

      render json: { ticket: serialize_one(ticket.reload, TicketDetailSerializer, staff: staff?) }
    end
  end
end
