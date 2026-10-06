# frozen_string_literal: true

module ::TicketingSystem
  # One entry in a ticket's timeline.
  #
  # `cooked` is HTML produced by PrettyText, which sanitises as it renders. The
  # client inserts it with `htmlSafe` — that is safe precisely because the value
  # is already sanitised server-side, and it is why the raw `body` is shipped
  # alongside it for the edit form rather than being rendered directly.
  class MessageSerializer < ::ApplicationSerializer
    include ::TicketingSystem::Serialization

    attributes :id,
               :ticket_id,
               :user_id,
               :user,
               :body,
               :cooked,
               :internal,
               :staff,
               :excerpt,
               :uploads,
               :created_at,
               :updated_at

    def user
      user_summary(object.user)
    end

    # Attachments, serialised by core's UploadSerializer and not by hand.
    #
    # `UploadSerializer#url` is where the `secure_uploads` rewrite to
    # /secure-uploads/… happens. A hash built here would look right in the JSON
    # and 404 in the browser on any forum with secure uploads enabled — see
    # TicketingSystem::Attachments for the full account.
    #
    # Internal notes carry their attachments through this same path, and that is
    # safe: the requester's payload never contains an internal note at all
    # (`TicketDetailSerializer#messages` filters them at the query), so the note's
    # attachments are never sent to them either.
    def uploads
      Attachments.serialize(object.uploads)
    end

    # `internal?` would be the natural name, but it is also what ActiveRecord
    # generates for the boolean column — and `ActiveModel::Serialization` reads
    # every declared attribute with `send`, so a declared name must resolve to a
    # column, an association, a model method, or a reader defined right here.
    # Naming the attribute after the column keeps that true.
    def internal
      object.internal?
    end

    def staff
      object.staff?
    end

    def excerpt
      object.excerpt
    end
  end
end
