# frozen_string_literal: true

class CreateTicketingSystemEvents < ActiveRecord::Migration[8.0]
  def change
    create_table :ticketing_system_events do |t|
      t.references :ticket,
                   null: false,
                   index: false,
                   foreign_key: {
                     to_table: :ticketing_system_tickets,
                     on_delete: :cascade,
                   }

      # Who caused the change. Nullable because the system itself can act (a
      # future auto-close, or a department change applied by a rake task), and a
      # null actor reads as "system" rather than blocking the write.
      t.bigint :actor_id

      # A string, not an integer: this table is an append-only log read by humans
      # in the ticket timeline, and adding a kind must never require touching
      # existing rows. Valid values live in Constants::EVENT_KINDS.
      t.string :kind, null: false, limit: 40

      # Previous and next values for the changed attribute, stored as text so one
      # pair of columns covers every kind — a status change stores "open" ->
      # "closed", an assignment stores nil -> "username".
      t.string :from_value
      t.string :to_value

      t.timestamps
    end

    add_index :ticketing_system_events, %i[ticket_id created_at id],
              name: "idx_ticketing_events_timeline"
  end
end
