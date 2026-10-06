# frozen_string_literal: true

module ::TicketingSystem
  class MessagesController < BaseController
    # Appends a reply or an internal note and returns the whole ticket.
    #
    # Returning the ticket rather than just the new message is deliberate: a reply
    # can change the status (a staff reply moves `open` to `in_progress`, a
    # requester's reply moves `pending` back to `open`), can reopen a finished
    # ticket, and always moves the counters. Re-fetching afterwards would be a
    # second round trip for data the server already has.
    def create
      ticket = find_ticket!(params[:id])

      result =
        MessageCreator.create!(
          ticket: ticket,
          user: current_user,
          body: params[:body],
          internal: params[:internal],
          upload_ids: params[:upload_ids],
        )

      # `reload` clears the association caches the creator populated, so the
      # serializer reads the committed rows rather than the in-memory ones.
      #
      # `read_markers` is resolved after the write for the same reason as in
      # TicketsController#show: the creator has just marked the author as having
      # read the thread, and the payload must agree with the database.
      ticket = result.ticket.reload

      render json: {
               ticket:
                 serialize_one(
                   ticket,
                   TicketDetailSerializer,
                   staff: staff?,
                   read_markers: read_markers_for([ticket]),
                 ),
               message_id: result.message.id,
             }
    end
  end
end
