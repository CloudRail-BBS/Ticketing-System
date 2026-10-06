# frozen_string_literal: true

module ::TicketingSystem
  # Closes tickets that have been sitting in `resolved` for long enough.
  #
  # WHY THIS EXISTS
  #
  # `resolved` means "we believe this is fixed, tell us if it is not". It is a
  # waiting state, and a waiting state with no deadline accumulates forever: a
  # queue where half the tickets are resolved-but-unconfirmed is a queue nobody
  # can read a workload from. After a grace period the ticket becomes `closed`,
  # which is a decision rather than a hope.
  #
  # WHY IT DOES NOT TOUCH `last_activity_at`
  #
  # `TicketUpdater#change_status!` bumps `last_activity_at` on a manual close,
  # and this deliberately does not. The two are different events: a person
  # closing one ticket is activity, while a sweep closing two hundred of them at
  # 03:00 would dump the entire backlog at the top of every "recently active"
  # list — for staff, for the requester, and for the admin overview. The closure
  # is recorded where it belongs, in `closed_at` and in the audit trail.
  #
  # WHY IT IS NOT MARKED READ
  #
  # Closing is housekeeping on a ticket the requester has already been told about
  # when it was resolved. Badging them for it would be a second interruption for
  # the same news; they get a notification instead, which is dismissible and does
  # not compete with the unread badge's meaning.
  class AutoCloser
    # Bounded per run. The job runs daily, so a backlog drains over a few days
    # rather than in one transaction that holds locks on thousands of rows.
    # Oldest first, so the tickets that have waited longest close first.
    BATCH_SIZE = 500

    def self.call
      new.call
    end

    def call
      return 0 unless Permissions.enabled?

      days = SiteSetting.ticketing_system_auto_close_days.to_i
      # 0 disables the feature, which is the documented meaning of the setting —
      # not "close immediately".
      return 0 if days <= 0

      now = Time.zone.now
      cutoff = days.days.ago(now)

      # A resolved ticket with a nil `resolved_at` is skipped by the comparison
      # (NULL <= x is NULL, never true). That is the safe direction: a ticket
      # whose resolution date cannot be established is not silently closed.
      Ticket
        .where(status: Constants::STATUSES[:resolved])
        .where(resolved_at: ..cutoff)
        .order(:resolved_at, :id)
        .limit(BATCH_SIZE)
        .to_a
        .each { |ticket| close(ticket, now) }
    end

    private

    def close(ticket, now)
      previous = ticket.status

      ticket.status = "closed"
      ticket.closed_at = now
      # NOT `last_activity_at`. See the class comment.
      ticket.save!

      Event.record!(
        ticket: ticket,
        kind: "auto_closed",
        from: previous,
        to: "closed",
      )

      Notifier.auto_closed(ticket)
    rescue StandardError => e
      # One bad row must not stop the sweep. The next run will try it again, and
      # in the meantime the failure is in the log rather than swallowed.
      Rails.logger.warn(
        "[ticketing-system] could not auto-close ticket #{ticket.try(:id)}: #{e.class} #{e.message}",
      )
      nil
    end
  end
end
