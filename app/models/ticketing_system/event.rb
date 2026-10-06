# frozen_string_literal: true

module ::TicketingSystem
  # Append-only audit trail.
  #
  # Messages already record the conversation, so this table exists for the things
  # a message cannot express: who changed the status, who took the ticket, when
  # it was resolved. The ticket timeline renders messages and events interleaved
  # by timestamp, which is why both tables carry a `(ticket_id, created_at, id)`
  # index.
  #
  # Nothing in this plugin ever updates or deletes a row here. That is the point:
  # "who closed this and when" must stay answerable even after the ticket is
  # reopened several times.
  class Event < ActiveRecord::Base
    self.table_name = "ticketing_system_events"

    belongs_to :ticket,
               class_name: "TicketingSystem::Ticket",
               foreign_key: :ticket_id,
               inverse_of: :events
    belongs_to :actor, class_name: "User", foreign_key: :actor_id, optional: true

    validates :kind, presence: true, inclusion: { in: Constants::EVENT_KINDS }

    # Writes one row, and never raises into a caller's happy path.
    #
    # A failed audit write must not roll back the change it was recording — a
    # status change that succeeded in the database but whose log line failed is
    # strictly better than a status change the user was told succeeded and which
    # did not happen. The failure is logged loudly instead.
    def self.record!(ticket:, kind:, actor: nil, from: nil, to: nil)
      create!(
        ticket_id: ticket.is_a?(ActiveRecord::Base) ? ticket.id : ticket,
        actor_id: actor&.id,
        kind: kind.to_s,
        from_value: from.nil? ? nil : from.to_s,
        to_value: to.nil? ? nil : to.to_s,
      )
    rescue StandardError => e
      Rails.logger.warn(
        "[ticketing-system] could not record event #{kind} for ticket #{ticket.try(:id)}: #{e.class} #{e.message}",
      )
      nil
    end
  end
end
