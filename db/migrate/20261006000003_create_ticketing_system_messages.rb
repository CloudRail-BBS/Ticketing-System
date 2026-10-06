# frozen_string_literal: true

class CreateTicketingSystemMessages < ActiveRecord::Migration[8.0]
  def change
    create_table :ticketing_system_messages do |t|
      # `on_delete: :cascade` here, unlike departments: a message has no meaning
      # without its ticket, and leaving orphans behind would make the timeline
      # query return rows whose ticket cannot be loaded.
      t.references :ticket,
                   null: false,
                   index: false,
                   foreign_key: {
                     to_table: :ticketing_system_tickets,
                     on_delete: :cascade,
                   }

      # Same reasoning as tickets.requester_id: no FK to `users`, so an admin
      # hard-deleting a user cannot fail on a plugin table.
      t.bigint :user_id, null: false

      # `body` is the author's Markdown; `cooked` is PrettyText's sanitised HTML.
      # Both are stored, exactly like core's posts table, so rendering a ticket
      # timeline is one query with no per-message Markdown pass.
      t.text :body, null: false
      t.text :cooked, null: false, default: ""

      # Internal notes are staff-only and are filtered out of every requester
      # response at the query level, never in the serializer.
      t.boolean :internal, null: false, default: false

      # Snapshot of whether the author was staff AT THE TIME OF WRITING. Reading
      # it live from the author's group membership would retroactively change how
      # an old message is attributed the moment someone joins or leaves staff,
      # which is exactly the kind of drift an audit trail must not have.
      t.boolean :staff, null: false, default: false

      t.timestamps
    end

    # The timeline query, and the only ordering a ticket ever needs.
    add_index :ticketing_system_messages, %i[ticket_id created_at id],
              name: "idx_ticketing_messages_timeline"
    add_index :ticketing_system_messages, %i[ticket_id internal],
              name: "idx_ticketing_messages_visibility"
  end
end
