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
            read_markers: read_markers_for(result.tickets),
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

      render json: {
               ticket:
                 serialize_one(
                   ticket,
                   TicketDetailSerializer,
                   staff: staff?,
                   # Computed AFTER mark_read!, so the payload the client renders
                   # reflects what the user just did. Computing it first would
                   # tell the page it is unread while clearing it in the
                   # database, and the badge would stay lit until the next load.
                   read_markers: read_markers_for([ticket]),
                 ),
             }
    end

    def create
      result =
        TicketCreator.create!(
          user: current_user,
          title: params[:title],
          body: params[:body],
          department: params[:department].presence || params[:department_id],
          priority: params[:priority],
          upload_ids: params[:upload_ids],
        )

      render json: {
               ticket:
                 serialize_one(
                   result.ticket,
                   TicketDetailSerializer,
                   staff: staff?,
                   read_markers: read_markers_for([result.ticket]),
                 ),
             },
             status: :created
    end
  end
end
