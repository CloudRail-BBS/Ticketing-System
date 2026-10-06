# frozen_string_literal: true

module ::TicketingSystem
  # The attribute methods shared by TicketSerializer (list rows) and
  # TicketDetailSerializer (one ticket, with its timeline).
  #
  # The two serializers declare their own `attributes` lists — deliberately, and
  # visibly — but every method behind those names lives here, so a change to how
  # a ticket renders cannot land in one view and miss the other.
  #
  # `ActiveModel::Serialization` reads each declared attribute with `send`, so a
  # name in an `attributes` list that resolves to nothing raises NoMethodError and
  # 500s EVERY endpoint sharing the serializer. Keeping the definitions in one
  # place makes that failure mode much easier to reason about.
  module TicketSerialization
    def display_number
      object.display_number
    end

    def status
      object.status
    end

    def status_label
      I18n.t("ticketing_system.status.#{object.status}")
    end

    def priority
      object.priority
    end

    def priority_label
      I18n.t("ticketing_system.priority.#{object.priority}")
    end

    def department
      department_summary(object.department)
    end

    def requester
      user_summary(object.requester)
    end

    def assignee
      user_summary(object.assignee)
    end

    # "Unread" is viewer-relative, so it is resolved once here rather than
    # shipping both counters and making every client decide which one to read.
    def unread
      staff? ? object.unread_for_staff? : object.unread_for_requester?
    end

    def sla
      object.sla
    end

    # Exactly the actions the server will accept, so the UI cannot offer a button
    # the controller then rejects.
    def can
      Permissions.ticket_capabilities(current_user, object, staff: staff?)
    end

    # Supplied by the controller as one extra query for the whole page
    # (`options[:excerpts]`), rather than one query per row.
    def excerpt
      options[:excerpts].to_h[object.id]
    end

    # Built from the primary key, which is always present on a persisted ticket —
    # but guarded anyway, because interpolating a nil would produce the literal
    # string "undefined" in a URL and 404 with nothing logged.
    def url
      return nil if object.id.blank?
      "/tickets/#{object.id}"
    end
  end
end
