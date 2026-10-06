# frozen_string_literal: true

class CreateTicketingSystemTickets < ActiveRecord::Migration[8.0]
  def change
    create_table :ticketing_system_tickets do |t|
      t.string :title, null: false, limit: 255

      # Integer, matching TicketingSystem::Constants::STATUSES / PRIORITIES.
      # Never renumber these values: they are what existing rows mean.
      t.integer :status, null: false, default: 0
      t.integer :priority, null: false, default: 1

      # The user who opened the ticket. Deliberately WITHOUT a foreign key to
      # `users`: Discourse anonymises and soft-deletes users rather than removing
      # rows, but an admin can hard-delete one, and an FK here would turn that
      # into a database error in an unrelated admin action. The model-level
      # `belongs_to` is the contract; the column is indexed so the "my tickets"
      # query never scans.
      # `index: false` on all three: each is the leading column of a composite
      # index added below, so a single-column index would be a strict duplicate —
      # pure write cost and disk, with nothing to gain. Postgres does not create
      # an index for a foreign key automatically, and the composite
      # `[department_id, status, last_activity_at]` serves the FK check.
      t.references :requester, null: false, index: false

      # Nullable: an unassigned ticket is the normal initial state.
      t.references :assignee, index: false

      # Nullable, with a real FK: departments are owned by this plugin, and
      # deleting one should not delete its tickets — it should leave them in an
      # unassigned-to-department state that staff can still work.
      t.references :department,
                   index: false,
                   foreign_key: {
                     to_table: :ticketing_system_departments,
                     on_delete: :nullify,
                   }

      # Denormalised counters. They exist so the list view and the unread badge
      # are single indexed reads instead of COUNT(*) over the messages table for
      # every row on every page.
      t.integer :message_count, null: false, default: 0
      t.integer :staff_message_count, null: false, default: 0

      # Shared-inbox unread model: one counter per side, cleared when that side
      # opens the ticket. See Permissions.unread_counts for why this is not
      # per-user.
      t.integer :requester_unread_count, null: false, default: 0
      t.integer :staff_unread_count, null: false, default: 0

      t.datetime :requester_last_read_at
      t.datetime :staff_last_read_at

      # SLA facts, recorded rather than derived: the first staff reply is a
      # one-time event, and storing it keeps the "time to first response"
      # statistic a plain aggregate.
      t.datetime :first_staff_reply_at
      t.datetime :resolved_at
      t.datetime :closed_at

      # Sort key for every list view. Kept separate from `updated_at` because a
      # counter bump (a read) must not reorder the queue, and separate from
      # `created_at` because the newest reply is what staff triage on.
      t.datetime :last_activity_at, null: false

      t.timestamps
    end

    # One composite index per list query the API actually issues. The leading
    # column is always the equality filter, the trailing one the sort, so each
    # of these is usable end to end rather than just for the filter.
    add_index :ticketing_system_tickets, %i[status last_activity_at]
    add_index :ticketing_system_tickets, %i[requester_id status last_activity_at],
              name: "idx_ticketing_tickets_requester"
    add_index :ticketing_system_tickets, %i[assignee_id status last_activity_at],
              name: "idx_ticketing_tickets_assignee"
    add_index :ticketing_system_tickets, %i[department_id status last_activity_at],
              name: "idx_ticketing_tickets_department"

    # Supports the unread badge, which is a filtered count on every page load.
    add_index :ticketing_system_tickets, :staff_unread_count,
              where: "staff_unread_count > 0",
              name: "idx_ticketing_tickets_staff_unread"
    add_index :ticketing_system_tickets, :requester_unread_count,
              where: "requester_unread_count > 0",
              name: "idx_ticketing_tickets_requester_unread"
  end
end
