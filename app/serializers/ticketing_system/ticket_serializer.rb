# frozen_string_literal: true

module ::TicketingSystem
  # A ticket as it appears in a list. Everything here is either a column or a
  # cheap derivation, so a 20-row page is two queries (the page and its excerpts)
  # plus the eager-loaded associations.
  #
  # The conversation itself is NOT included — see TicketDetailSerializer. A list
  # of 20 tickets carrying their full message threads would be a payload nobody
  # reads and everybody pays for.
  class TicketSerializer < ::ApplicationSerializer
    include ::TicketingSystem::Serialization
    include ::TicketingSystem::TicketSerialization

    attributes :id,
               :display_number,
               :title,
               :status,
               :status_label,
               :priority,
               :priority_label,
               :department_id,
               :department,
               :requester_id,
               :requester,
               :assignee_id,
               :assignee,
               :message_count,
               :staff_message_count,
               :unread,
               :last_activity_at,
               :created_at,
               :updated_at,
               :resolved_at,
               :closed_at,
               :first_staff_reply_at,
               :sla,
               :can,
               :excerpt,
               :url
  end
end
