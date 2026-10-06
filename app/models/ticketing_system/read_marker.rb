# frozen_string_literal: true

module ::TicketingSystem
  # One reader's "I have seen this ticket up to here" row.
  #
  # WHY THIS TABLE EXISTS
  #
  # The obvious model — a counter on the ticket — answers "has anyone looked?"
  # rather than "has THIS person looked?". With a support queue worked by more
  # than one person those are different questions, and the counter answers the
  # wrong one: the first staff member to open a ticket clears the badge for the
  # whole team, so the people who have not looked are exactly the people the
  # badge stops warning.
  #
  # WHAT "UNREAD" MEANS HERE
  #
  # There is no `unread` boolean anywhere. A reader is behind when the other
  # side has spoken since they last read:
  #
  #   staff are behind   when ticket.last_requester_message_at > marker.last_read_at
  #   requester is behind when ticket.last_staff_message_at    > marker.last_read_at
  #
  # Deriving it rather than storing it is what keeps the two from disagreeing.
  # A stored flag has to be cleared when a message arrives and set when a ticket
  # is opened, and every path that writes a message or opens a ticket is another
  # chance to get that wrong — with the failure surfacing as a badge that never
  # clears, which looks like a caching bug and is not one.
  #
  # The two per-side timestamps live on the ticket because they are facts about
  # MESSAGES, not about reads, so they do not duplicate anything here. They also
  # make the answer a comparison of two columns on a row already being fetched,
  # instead of a scan over the messages table.
  class ReadMarker < ActiveRecord::Base
    self.table_name = "ticketing_system_read_markers"

    belongs_to :ticket,
               class_name: "TicketingSystem::Ticket",
               foreign_key: :ticket_id,
               inverse_of: :read_markers

    belongs_to :user, class_name: "User", foreign_key: :user_id

    validates :last_read_at, presence: true

    # The columns of the unique index added in the migration. Named once here
    # because both write paths have to point Postgres at the same conflict
    # target, and a typo in one of them would only show up as a duplicate row
    # under concurrency — the hardest kind of bug to reproduce.
    UNIQUE_BY = %i[ticket_id user_id].freeze

    class << self
      # Records that `user` has seen `ticket` as of `at` (default: now).
      #
      # `at` is a parameter rather than always `Time.zone.now` because the two
      # callers mean different instants: opening a ticket means "now", while
      # posting a message means "when I wrote this" — and the author of a message
      # has read the thread up to their own message, no further. Using `now` there
      # would be harmless today and wrong the moment a message is created with a
      # backdated timestamp.
      #
      # Returns nothing. Nothing calls this for its return value, and returning
      # the row would mean a second query to reload it.
      def mark_read!(ticket:, user:, at: nil)
        at ||= Time.zone.now
        now = Time.zone.now

        # `insert_all` rather than find-then-save, for two reasons.
        #
        # CONCURRENCY: a double-clicked ticket sends two requests, and
        # find-then-save would have both miss and then both insert, so the
        # second raises on the unique index — turning an ordinary double-click
        # into a 500 for the user who was only trying to open a ticket.
        #
        # MONOTONICITY: the conflict action takes the later of the two
        # timestamps. A plain upsert would let the older request win whenever it
        # happened to commit last, moving the marker backwards and re-flagging
        # messages the reader had already seen.
        #
        # This skips validations and callbacks deliberately: there is nothing to
        # validate beyond the presence of `last_read_at` (which is always set
        # here) and no callback on this model.
        insert_all(
          [
            {
              ticket_id: ticket.id,
              user_id: user.id,
              last_read_at: at,
              created_at: now,
              updated_at: now,
            },
          ],
          unique_by: UNIQUE_BY,
          on_duplicate:
            Arel.sql(
              "last_read_at = GREATEST(#{table_name}.last_read_at, EXCLUDED.last_read_at), " \
                "updated_at = EXCLUDED.updated_at",
            ),
        )
      end

      # `{ticket_id => last_read_at}` for one reader across a set of tickets.
      #
      # Takes the whole page at once because the alternative is a query per row
      # inside the serializer, and a list page would issue twenty of them.
      def last_read_map(ticket_ids, user_id)
        return {} if ticket_ids.blank? || user_id.blank?

        where(ticket_id: ticket_ids, user_id: user_id).pluck(:ticket_id, :last_read_at).to_h
      end
    end
  end
end
