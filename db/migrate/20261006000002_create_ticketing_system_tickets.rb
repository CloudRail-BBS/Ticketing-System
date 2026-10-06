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

      # Denormalised counters. They exist so the list view is a single indexed
      # read instead of COUNT(*) over the messages table for every row on every
      # page.
      t.integer :message_count, null: false, default: 0
      t.integer :staff_message_count, null: false, default: 0

      # NO UNREAD COUNTERS HERE, deliberately.
      #
      # An earlier revision kept `requester_unread_count` / `staff_unread_count`
      # on this row, which made "unread" a property of the TICKET rather than of
      # a reader. That is the shared-inbox model: one staff member opening a
      # ticket clears the badge for the whole team — and with several people
      # working a queue, the person who has not looked is exactly the person the
      # badge is for.
      #
      # Read state now lives per reader in ticketing_system_read_markers, keyed
      # `(ticket_id, user_id)`, for requesters and staff alike. It is NOT kept
      # here as a fast path as well, because two sources of truth for one
      # question is how the two end up disagreeing — and the disagreement would
      # surface as a badge that never clears.
      #
      # The per-side timestamps below are what keeps that affordable. "Unread"
      # for a reader is then a comparison of two datetimes on this row against
      # their marker, with no scan of the messages table: a requester is behind
      # if a staff member spoke after they last read, staff are behind if the
      # requester did. Those are facts about MESSAGES, not about reads, so they
      # do not duplicate the read markers.
      t.datetime :last_requester_message_at
      t.datetime :last_staff_message_at

      # SLA facts, recorded rather than derived: the first staff reply is a
      # one-time event, and storing it keeps the "time to first response"
      # statistic a plain aggregate.
      t.datetime :first_staff_reply_at
      t.datetime :resolved_at
      t.datetime :closed_at

      # Set by the SLA sweep job when it has told staff this ticket is overdue.
      # The column is what makes that job idempotent: without it the sweep would
      # re-notify the same ticket every time it runs.
      t.datetime :sla_notified_at

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
    #
    # There is deliberately no partial index on the unread test itself. The test
    # is `t.last_requester_message_at > m.last_read_at`, where the right-hand
    # side differs per reader — so no index on a single column of this table can
    # serve it. What makes the query cheap is the narrow candidate set: the
    # composite indexes above already restrict the scan to one department (or
    # one requester) and the open statuses, and the datetimes are then compared
    # on rows already fetched. Adding an index here would be write cost against
    # a predicate Postgres cannot use.
  end
end
