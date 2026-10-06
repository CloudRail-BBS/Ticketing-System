# frozen_string_literal: true

# Repairs databases that migrated BEFORE `20261006000002` was rewritten in place.
#
# WHAT WENT WRONG
#
# The original revision of 20261006000002 created a shared-inbox unread model: a
# counter and a read stamp per side (`requester_unread_count` /
# `staff_unread_count`, `requester_last_read_at` / `staff_last_read_at`). A later
# commit replaced that with per-reader state — `last_requester_message_at` /
# `last_staff_message_at` on this table, plus a `read_markers` row per
# `(ticket, user)` — and added `sla_notified_at` for the reminder job.
#
# The replacement was written by editing 20261006000002 itself. For a migration
# that has ALREADY RUN that is a no-op: Rails decides what to run by looking up
# versions in `schema_migrations`, not by comparing file contents, so a database
# that ran the original never re-runs it and never grows the three new columns.
#
# The failure is therefore silent at deploy time and loud at request time: the
# first list request reads a column that is not there, Postgres raises
# `PG::UndefinedColumn`, and `/tickets` plus `/tickets/api/meta` both answer 500.
# `/meta` is also where the client gets its scope list, so the visible symptom was
# not only an error page but a scope picker collapsed to a single entry.
#
# THE RULE THIS ENCODES
#
# Never edit a migration that has shipped. Add one. This file is that one, and it
# is idempotent in both directions so that a FRESH install — where 20261006000002
# already creates all three columns — runs it as a no-op instead of aborting with
# "column already exists".
class FixTicketingSystemTicketUnreadColumns < ActiveRecord::Migration[8.0]
  def up
    # `if_not_exists` is what makes this safe on both histories. Without it a
    # fresh install aborts here, because the rewritten 20261006000002 created
    # these columns a moment earlier.
    add_column :ticketing_system_tickets, :last_requester_message_at, :datetime,
               if_not_exists: true
    add_column :ticketing_system_tickets, :last_staff_message_at, :datetime,
               if_not_exists: true
    add_column :ticketing_system_tickets, :sla_notified_at, :datetime,
               if_not_exists: true

    backfill_message_boundaries
    drop_shared_inbox_columns
  end

  # Not reversible, and honestly so. The columns dropped below held shared-inbox
  # counters whose values were already meaningless — one staff member's read
  # zeroed the whole team's badge — and the backfill cannot be undone either,
  # because it fills gaps rather than overwriting. Recreating empty columns would
  # restore the SHAPE of the old schema while silently losing the data, which is
  # worse than refusing.
  def down
    raise ActiveRecord::IrreversibleMigration, <<~MESSAGE
      FixTicketingSystemTicketUnreadColumns is a repair migration, not a schema
      change: it reconciles databases that ran the pre-rewrite revision of
      20261006000002 with the schema the code now expects. Rolling it back would
      have to decide which of the two histories to return to, and would discard
      the backfilled message timestamps either way. Restore from a backup if you
      genuinely need the previous shape.
    MESSAGE
  end

  private

  # Fills the two boundaries from the messages table instead of leaving them NULL.
  #
  # This matters because of how "unread" is decided. `Ticket.unread_for` starts
  # from `where.not(boundary => nil)`, and `Ticket#unread_for?` returns false when
  # the boundary is blank — so a NULL boundary means "never unread", not "always
  # unread". Skipping the backfill would therefore not produce a wrong badge; it
  # would produce NO badge on every ticket that already exists, silently, until
  # the next message happens to arrive on each one. Nobody reports that as a bug.
  # They just stop trusting the badge.
  #
  # The computation mirrors `MessageCreator#apply_counters` exactly:
  #
  #   * `internal = FALSE`, because an internal note is staff bookkeeping and
  #     deliberately moves neither boundary — the requester cannot see it, so it
  #     must not badge them.
  #   * one `MAX(created_at)` per side, which is what the runtime stores: each
  #     message overwrites the column with its own `created_at`, so the last write
  #     wins and therefore equals the maximum.
  #
  # COALESCE rather than a plain assignment: this only ever fills a gap. A
  # database that already has correct values keeps them, so the statement is safe
  # on a fresh install and safe to re-run.
  #
  # `sla_notified_at` is deliberately NOT backfilled. The sweep job selects
  # `sla_notified_at IS NULL` and computes the deadline from `created_at`, so
  # leaving it NULL means the first run reports the tickets that are genuinely
  # overdue right now — which is the entire point of the feature. Stamping it to
  # suppress that first batch would silently drop real reminders. The job is
  # batched at 200 per run precisely so a backlog drains in order instead of
  # arriving as one flood.
  def backfill_message_boundaries
    say_with_time "Backfilling ticketing message boundaries from messages" do
      connection.update(<<~SQL)
        UPDATE ticketing_system_tickets AS t
        SET last_requester_message_at =
              COALESCE(t.last_requester_message_at, agg.requester_at),
            last_staff_message_at =
              COALESCE(t.last_staff_message_at, agg.staff_at)
        FROM (
          SELECT m.ticket_id,
                 MAX(m.created_at) FILTER (WHERE m."staff" = FALSE) AS requester_at,
                 MAX(m.created_at) FILTER (WHERE m."staff" = TRUE)  AS staff_at
          FROM ticketing_system_messages AS m
          WHERE m."internal" = FALSE
          GROUP BY m.ticket_id
        ) AS agg
        WHERE agg.ticket_id = t.id
          AND (t.last_requester_message_at IS NULL
               OR t.last_staff_message_at IS NULL)
      SQL
    end
  end

  # Brings the table back to the shape a fresh install has. These four columns and
  # their two partial indexes are what the rewrite replaced, and nothing in the
  # plugin reads them (a `grep` for either name finds only this migration), so on a
  # database that still has them they are pure write cost — and, worse, a
  # documented-schema lie: the table's own comment says "NO UNREAD COUNTERS HERE".
  #
  # `if_exists: true` because a fresh install never created them, so there this is
  # a no-op rather than an error. The partial indexes go with their columns;
  # Postgres drops an index that depends on a dropped column automatically, so
  # there is nothing to name here.
  #
  # If you would rather keep the dead columns — for example because something
  # outside this plugin queries them — delete this call. Nothing else in the
  # migration depends on it, and the three added columns are what the 500 needs.
  def drop_shared_inbox_columns
    remove_column :ticketing_system_tickets, :requester_unread_count, if_exists: true
    remove_column :ticketing_system_tickets, :staff_unread_count, if_exists: true
    remove_column :ticketing_system_tickets, :requester_last_read_at, if_exists: true
    remove_column :ticketing_system_tickets, :staff_last_read_at, if_exists: true
  end
end
