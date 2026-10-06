# frozen_string_literal: true

module ::TicketingSystem
  # One line in the ticket's audit trail.
  #
  # `kind` is the machine value (see Constants::EVENT_KINDS) and `kind_label` is
  # the translated one. Both are shipped: the client renders the label, and
  # branches on the kind when it needs to (e.g. to hide the assignee line from a
  # requester).
  class EventSerializer < ::ApplicationSerializer
    include ::TicketingSystem::Serialization

    attributes :id,
               :ticket_id,
               :kind,
               :kind_label,
               :actor,
               :from_value,
               :to_value,
               :created_at

    def kind_label
      I18n.t("ticketing_system.event.#{object.kind}", default: object.kind)
    end

    def actor
      user_summary(object.actor)
    end
  end
end
