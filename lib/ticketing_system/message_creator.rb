# frozen_string_literal: true

module ::TicketingSystem
  # Appends a public reply or a staff-only internal note, and applies the state
  # transitions a reply implies.
  #
  # Those transitions live here rather than in the controller because they are
  # invariants of the ticket, not of the HTTP request: a reply from staff to an
  # `open` ticket means it is being worked on, and a reply from the requester to
  # a `pending` ticket means the ball is back with staff. Any other entry point
  # (a rake task, a future mail-in channel) has to get the same behaviour.
  class MessageCreator
    Result = Struct.new(:ticket, :message, keyword_init: true)

    def self.create!(ticket:, user:, body:, internal: false, upload_ids: nil)
      new(ticket: ticket, user: user, body: body, internal: internal, upload_ids: upload_ids).create!
    end

    def initialize(ticket:, user:, body:, internal: false, upload_ids: nil)
      @ticket = ticket
      @user = user
      @body = body.to_s
      @internal = ActiveModel::Type::Boolean.new.cast(internal)
      @upload_ids = upload_ids
    end

    def create!
      ensure_enabled!
      ensure_permitted!
      RateLimiter.check_reply!(@user)

      # Validated OUTSIDE the transaction. Two reasons: an attachment the user
      # may not use should not leave a half-written message behind, and this does
      # a handful of queries that have no business holding a write transaction
      # open while they run.
      attachment_ids = Attachments.validate!(user: @user, upload_ids: @upload_ids)

      message = nil

      ActiveRecord::Base.transaction do
        message = @ticket.messages.create!(
          user_id: @user.id,
          body: @body,
          internal: @internal,
          staff: user_is_staff?,
        )

        apply_counters(message)
        apply_status_transition
        @ticket.last_activity_at = message.created_at
        @ticket.save!

        Attachments.attach!(target: message, upload_ids: attachment_ids)

        # The author has read the thread up to their own message, and only that
        # far: `at: message.created_at` rather than `now`, so a later reply from
        # the other side still registers as unread. Without this the author's own
        # reply would leave them flagged as behind on the conversation they just
        # joined — which is what the old per-ticket counters used to clear.
        ReadMarker.mark_read!(ticket: @ticket, user: @user, at: message.created_at)

        Event.record!(
          ticket: @ticket,
          actor: @user,
          kind: @internal ? "internal_note" : "replied",
        )
      end

      Notifier.message_created(@ticket, message)

      Result.new(ticket: @ticket, message: message)
    end

    private

    def ensure_enabled!
      raise Errors::Disabled.new unless Permissions.enabled?
    end

    def user_is_staff?
      @user_is_staff = Permissions.staff?(@user) if @user_is_staff.nil?
      @user_is_staff
    end

    def ensure_permitted!
      permitted =
        if @internal
          Permissions.can_write_internal_note?(@user, @ticket)
        else
          Permissions.can_reply?(@user, @ticket)
        end

      return if permitted

      # Distinct keys so the frontend can say something useful instead of a bare
      # "forbidden": "this ticket is closed" is actionable, "you may not do that"
      # is not.
      key =
        if @internal
          :internal_notes_not_allowed
        elsif @ticket.closed?
          :ticket_closed
        else
          :forbidden
        end

      raise Errors::Forbidden.new(key)
    end

    # Counters and per-side timestamps.
    #
    # The two `last_*_message_at` columns are what the unread badge compares
    # against a reader's marker, so this is the ONLY place that has to move them:
    # no read state is written here at all. The old version of this method also
    # zeroed the other side's unread counter, which is exactly the shared-inbox
    # behaviour that made one staff member's read clear the whole team's badge.
    #
    # Internal notes deliberately touch neither timestamp. They are staff
    # bookkeeping: a note is not "the staff side spoke" to the requester, who
    # cannot see it, and treating it as such would badge them for something they
    # will never be shown.
    def apply_counters(message)
      if @internal
        @ticket.staff_message_count = @ticket.staff_message_count.to_i + 1
        return
      end

      @ticket.message_count = @ticket.message_count.to_i + 1

      if user_is_staff?
        @ticket.staff_message_count = @ticket.staff_message_count.to_i + 1
        @ticket.last_staff_message_at = message.created_at
        # `||=` so a later staff reply cannot move the first-response timestamp
        # that the SLA statistic is built on.
        @ticket.first_staff_reply_at ||= message.created_at
      else
        @ticket.last_requester_message_at = message.created_at
      end
    end

    def apply_status_transition
      return if @internal

      # Captured before any assignment. `status_was` would work too, but reading
      # the value explicitly makes the audit trail's correctness independent of
      # dirty-tracking semantics.
      previous = @ticket.status

      if user_is_staff?
        # A staff reply on a finished ticket reopens it. Without this a ticket
        # closed by mistake would be a dead end: the requester cannot reply to a
        # closed ticket, and staff would have to remember to change the status
        # first, which nobody does.
        if @ticket.finished?
          @ticket.status = :in_progress
          @ticket.resolved_at = nil
          @ticket.closed_at = nil
          Event.record!(
            ticket: @ticket,
            actor: @user,
            kind: "reopened",
            from: previous,
            to: "in_progress",
          )
        elsif @ticket.open?
          # No event: the reply that caused it is already in the timeline, and a
          # second line saying "status changed" for every first staff reply is
          # noise. The change is still visible because the status field moved.
          @ticket.status = :in_progress
        end
      elsif @ticket.pending?
        # The requester answered, so the ticket is no longer waiting on them.
        @ticket.status = :open
      end
    end
  end
end
