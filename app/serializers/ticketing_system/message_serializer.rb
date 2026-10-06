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
               :created_at,
               :updated_at

    def user
      user_summary(object.user)
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
