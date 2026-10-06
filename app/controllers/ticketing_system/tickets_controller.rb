# frozen_string_literal: true

module ::TicketingSystem
  class TicketsController < BaseController
    def index
      result = TicketQuery.new(user: current_user, params: params).call

      render json: {
        tickets:
          serialize_many(
            result.tickets,
            TicketSerializer,
            staff: staff?,
            excerpts: excerpts_for(result.tickets),
          ),
        page: {
          total: result.total,
          page: result.page,
          per_page: result.per_page,
          pages: result.pages,
          scope: result.scope,
          sort: result.sort,
        },
        unread: Permissions.unread_counts(current_user, staff: staff?),
      }
    end

    def show
      ticket = find_ticket!(params[:id])
      mark_read!(ticket)

      render json: { ticket: serialize_one(ticket, TicketDetailSerializer, staff: staff?) }
    end

    def create
      result =
        TicketCreator.create!(
          user: current_user,
          title: params[:title],
          body: params[:body],
          department: params[:department].presence || params[:department_id],
          priority: params[:priority],
        )

      render json: {
               ticket: serialize_one(result.ticket, TicketDetailSerializer, staff: staff?),
             },
             status: :created
    end
  end
end
