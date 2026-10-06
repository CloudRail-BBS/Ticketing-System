# frozen_string_literal: true

class CreateTicketingSystemReadMarkers < ActiveRecord::Migration[8.0]
  def change
    create_table :ticketing_system_read_markers do |t|
      # `on_delete: :cascade`, matching messages: a read marker has no meaning
      # without its ticket, and leaving orphans behind would leave rows the
      # unread query keeps scanning for a ticket nobody can load.
      t.references :ticket,
                   null: false,
                   index: false,
                   foreign_key: {
                     to_table: :ticketing_system_tickets,
                     on_delete: :cascade,
                   }

      # No FK to `users`, for the same reason as tickets.requester_id: an admin
      # hard-deleting a user must not fail on a plugin table.
      t.bigint :user_id, null: false

      # The instant the reader last looked at this ticket. Compared against
      # `tickets.last_requester_message_at` / `last_staff_message_at` to decide
      # whether they are behind — see Ticket.unread_for.
      #
      # NOT NULL, and there is no "unread" row: absence of a row already means
      # "has never opened it", which is exactly "everything is unread". A row
      # with a null timestamp would be a third state meaning the same thing as
      # absence, and the unread query would then need to handle both.
      t.datetime :last_read_at, null: false

      t.timestamps
    end

    # The only index this table needs, and it is the whole read model.
    #
    # One row per (ticket, reader) is an invariant, not a convention, so the
    # unique index is what enforces it — and it doubles as the lookup index for
    # both queries that exist:
    #
    #   * the unread test, `NOT EXISTS (… WHERE m.ticket_id = t.id AND
    #     m.user_id = ?)` — a correlated subquery, which needs exactly this
    #     column order;
    #   * "who has read this ticket", `WHERE ticket_id = ?`, which uses the
    #     leading column;
    #   * the per-page marker load, `WHERE ticket_id IN (…) AND user_id = ?`,
    #     which uses the leading column for the IN list and filters the rest.
    #
    # A second index leading with `user_id` was considered and rejected: no
    # query in the plugin starts from a user and looks up their markers. The
    # badge starts from the tickets and asks whether a marker exists.
    add_index :ticketing_system_read_markers,
              %i[ticket_id user_id],
              unique: true,
              name: "idx_ticketing_read_markers_unique"
  end
end
