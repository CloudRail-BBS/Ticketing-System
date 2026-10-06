# frozen_string_literal: true

# Brings a database that predates the per-reader unread model up to the shape the
# current code expects.
#
# WHY THIS EXISTS
#
# `20261006000002_create_ticketing_system_tickets` was edited in place after it
# had already been released and run. The shared-inbox unread counters and the two
# shared read timestamps were replaced by `last_requester_message_at` /
# `last_staff_message_at`, and `sla_notified_at` was added for the SLA sweep.
#
# Rails records a migration that has run in `schema_migrations` and never runs it
# again, so on every install created from the earlier revision those three columns
# do not exist — while the current code reads them on every ticket list request
# and on every page load (`Permissions.client_payload` -> `unread_counts` ->
# `Ticket.unread_for`). The symptom is a 500 whose message is a Postgres
# undefined-column error, which points at the query rather than at the schema, so
# it is worth stating plainly here: the columns were never created.
#
# Every step below is guarded, so on a database that already has the current shape
# (a fresh install runs the corrected `..._000002` and arrives here with nothing
# to do) this migration is a no-op.
class AddTicketingSystemPerReaderUnread < ActiveRecord::Migration[8.0]
  TICKETS = :ticketing_system_tickets
  MARKERS = :ticketing_system_read_markers

  def up
    add_missing_columns
    backfill_message_timestamps
    carry_over_requester_read_marker
    drop_shared_inbox_columns
  end

  # Not reversible in the usual sense, and refusing is more honest than a `down`
  # that looks like one.
  #
  # The columns dropped at the end held the shared-inbox read state, which the
  # per-reader model supersedes and which is not recoverable from anything that
  # remains. Recreating them empty would produce a schema that resembles the old
  # one and answers differently — a rollback that silently reports every ticket as
  # read is worse than a rollback that refuses.
  def down
    raise ActiveRecord::IrreversibleMigration,
          "the shared-inbox unread columns were dropped and their values are gone; " \
            "restore from a backup taken before this migration instead"
  end

  private

  def add_missing_columns
    unless column_exists?(TICKETS, :last_requester_message_at)
      add_column TICKETS, :last_requester_message_at, :datetime
    end

    unless column_exists?(TICKETS, :last_staff_message_at)
      add_column TICKETS, :last_staff_message_at, :datetime
    end

    unless column_exists?(TICKETS, :sla_notified_at)
      add_column TICKETS, :sla_notified_at, :datetime
    end
  end

  # Rebuilds the two denormalised timestamps from the messages table.
  #
  # A rebuild, not a guess: these values are a projection of rows that are still
  # present, and `messages.staff` is the very discriminator
  # `MessageCreator#apply_counters` uses to decide which of the two it writes, so
  # the result matches what the application would have stored.
  #
  # Internal notes are skipped for the same reason they are skipped there: a note
  # is staff bookkeeping, not "the staff side spoke", and the requester cannot see
  # it — counting one would badge them for something they will never be shown.
  def backfill_message_timestamps
    execute <<~SQL
      UPDATE ticketing_system_tickets AS t
      SET last_requester_message_at = (
            SELECT MAX(m.created_at)
            FROM ticketing_system_messages AS m
            WHERE m.ticket_id = t.id AND m.internal = FALSE AND m.staff = FALSE
          ),
          last_staff_message_at = (
            SELECT MAX(m.created_at)
            FROM ticketing_system_messages AS m
            WHERE m.ticket_id = t.id AND m.internal = FALSE AND m.staff = TRUE
          )
      WHERE t.last_requester_message_at IS NULL
        AND t.last_staff_message_at IS NULL
    SQL
  end

  # Carries the requester's read state across, and deliberately does not invent
  # one for staff.
  #
  # The old `requester_last_read_at` recorded exactly the fact the new table
  # stores, for a reader whose identity is never in question — the ticket names
  # them. It therefore moves over intact, and a requester does not suddenly see
  # every ticket they had already read as unread.
  #
  # `staff_last_read_at` is a different thing: it recorded that SOME staff member
  # had looked, with nothing saying which. Attributing it to any individual would
  # be fabricating data, and the alternative leaves staff with every existing
  # ticket unread. That is the truthful answer — the new model genuinely has no
  # record of who read what — and it clears the first time each ticket is opened.
  # It is also the safe direction: a one-time over-report of unread work is
  # recoverable, a silently cleared badge is not.
  def carry_over_requester_read_marker
    return unless column_exists?(TICKETS, :requester_last_read_at)
    return unless table_exists?(MARKERS)

    execute <<~SQL
      INSERT INTO ticketing_system_read_markers
        (ticket_id, user_id, last_read_at, created_at, updated_at)
      SELECT t.id, t.requester_id, t.requester_last_read_at, NOW(), NOW()
      FROM ticketing_system_tickets AS t
      WHERE t.requester_last_read_at IS NOT NULL
      ON CONFLICT (ticket_id, user_id) DO NOTHING
    SQL
  end

  # The old shared-inbox columns, and with them the partial indexes on the two
  # counters (Postgres drops an index along with its only column).
  #
  # Dropped rather than left behind, because a column the code no longer
  # maintains is a trap: it still reads as a valid answer to a question it no
  # longer answers. Migration `..._000002` already states the same rule for a
  # fresh install, and leaving an upgraded database with a different schema from
  # a fresh one is how a query comes to work in development and fail in
  # production.
  def drop_shared_inbox_columns
    remove_column TICKETS, :requester_unread_count, if_exists: true
    remove_column TICKETS, :staff_unread_count, if_exists: true
    remove_column TICKETS, :requester_last_read_at, if_exists: true
    remove_column TICKETS, :staff_last_read_at, if_exists: true
  end
end
