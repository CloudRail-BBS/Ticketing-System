# frozen_string_literal: true

module ::TicketingSystem
  # Tells staff, once, that a ticket has gone past a service-level deadline.
  #
  # WHY A JOB AT ALL, WHEN THE DEADLINE IS DERIVED
  #
  # `Ticket#sla` computes the deadline at read time, which is why a settings
  # change re-scores every ticket instantly and nothing can drift. That answers
  # "is this late?" on a page. It cannot answer "tell me when something becomes
  # late", because nothing is watching — a derived value has no moment of
  # transition. This job is that watcher, and it is the only piece of state the
  # feature adds: `tickets.sla_notified_at`.
  #
  # WHY IT IS IDEMPOTENT, AND WHY THAT IS THE WHOLE DESIGN
  #
  # A sweep runs every 15 minutes over the same rows, so without a marker it
  # would re-notify the same ticket ~96 times a day until someone replied. The
  # marker is claimed with a conditional UPDATE — `WHERE id = ? AND
  # sla_notified_at IS NULL` — and the notification only fires if that update
  # reported a row. Doing it in that order (claim, then notify) means two
  # overlapping runs cannot both notify: exactly one of them wins the update.
  #
  # The trade is that a crash between the claim and the notification loses that
  # one reminder, permanently. That is the right way round: a missed reminder is
  # a ticket still sitting in the queue with its deadline visibly breached, while
  # a duplicate is a person being told the same thing every 15 minutes until they
  # mute the notification type.
  #
  # WHAT IT DOES *NOT* NOTIFY ABOUT
  #
  # A ticket whose first reply was already late but which has since been answered
  # is not notified. That is a fact for the statistics page, not an action item:
  # there is nothing left to do about it. The sweep only reports work that is
  # still outstanding — no staff reply yet, or not resolved yet.
  #
  # ONE REMINDER PER TICKET, NOT ONE PER DEADLINE
  #
  # `sla_notified_at` is a single column, so a ticket that breaches its
  # first-response deadline and later its resolution deadline is announced once.
  # Two columns would be needed to announce both, and the second announcement
  # would arrive on a ticket the team has already been told about. The overdue
  # state stays visible on the ticket itself either way.
  class SlaSweeper
    # Bounded so one run cannot turn a backlog into a thundering herd of
    # notifications. Oldest first, so a backlog drains in order; anything left
    # over is picked up by the next run.
    BATCH_SIZE = 200

    Result = Struct.new(:notified, :skipped, keyword_init: true)

    def self.call
      new.call
    end

    def call
      return Result.new(notified: 0, skipped: 0) unless Permissions.enabled?

      # Checked here rather than only inside Notifier, so that turning reminders
      # off genuinely pauses the feature instead of quietly consuming the
      # `sla_notified_at` markers that a later switch-on would need.
      return Result.new(notified: 0, skipped: 0) unless SiteSetting.ticketing_system_overdue_reminders

      now = Time.zone.now
      notified = 0
      skipped = 0

      breaching(now).each do |ticket|
        if notify(ticket, now)
          notified += 1
        else
          skipped += 1
        end
      end

      Result.new(notified: notified, skipped: skipped)
    end

    private

    # The deadline rule, in SQL.
    #
    # This is the ONE place in the plugin where the SLA rule is expressed twice —
    # here and in `Ticket#sla` / `Ticket#sla_state` — and it is a deliberate
    # trade: the alternative is loading every open ticket into Ruby to compute a
    # date the database can compute for the whole table in one query.
    #
    # The COALESCE is what makes that necessary: the hours come from the ticket's
    # department when it has one and from the plugin setting otherwise, which
    # ActiveRecord's DSL can only express as two queries or an N+1. The two
    # spellings must stay in step; the shapes to keep aligned are
    # `COALESCE(departments.first_response_hours, global)` ↔
    # `Ticket#first_response_hours`, and the same for resolution.
    #
    # `preload(:department)` rather than `includes`: the join is needed for the
    # predicate, and preloading then loads the departments in one extra query so
    # `breach_kind` can call `first_response_due_at` without an N+1.
    def breaching(now)
      first_hours = SiteSetting.ticketing_system_first_response_hours.to_i
      resolution_hours = SiteSetting.ticketing_system_resolution_hours.to_i

      Ticket
        .active
        .where(sla_notified_at: nil)
        .left_joins(:department)
        .preload(:department)
        .where(
          "(" \
            "(ticketing_system_tickets.first_staff_reply_at IS NULL AND " \
              "ticketing_system_tickets.created_at + " \
              "(COALESCE(ticketing_system_departments.first_response_hours, ?) * INTERVAL '1 hour') < ?)" \
            " OR " \
            "(ticketing_system_tickets.resolved_at IS NULL AND " \
              "ticketing_system_tickets.created_at + " \
              "(COALESCE(ticketing_system_departments.resolution_hours, ?) * INTERVAL '1 hour') < ?)" \
            ")",
          first_hours,
          now,
          resolution_hours,
          now,
        )
        .order(:created_at, :id)
        .limit(BATCH_SIZE)
        .to_a
    end

    # Claims the ticket and, if the claim was won, announces it.
    def notify(ticket, now)
      kind = breach_kind(ticket, now)
      # The row matched the query, but by now a reply may have landed and cleared
      # the condition. Re-checking in Ruby is cheap and avoids announcing a
      # deadline that has just been met.
      return false if kind.nil?

      # The claim. `sla_notified_at IS NULL` is repeated in the WHERE so the
      # update is a no-op if another run already took this ticket — the check and
      # the write are one statement, which is the only way they can be atomic.
      claimed =
        Ticket
          .where(id: ticket.id, sla_notified_at: nil)
          .update_all(sla_notified_at: now, updated_at: now)

      return false if claimed.zero?

      ticket.sla_notified_at = now

      Event.record!(ticket: ticket, kind: "sla_breached", from: kind)
      Notifier.sla_breached(ticket, breach: kind)

      true
    end

    # Which deadline was missed. Mirrors `Ticket#sla_state`'s ordering: the first
    # response is reported in preference to the resolution when both are overdue,
    # because it is the earlier promise and the one the requester is waiting on.
    def breach_kind(ticket, now)
      if ticket.first_staff_reply_at.blank? && now > ticket.first_response_due_at
        "first_response"
      elsif ticket.resolved_at.blank? && now > ticket.resolution_due_at
        "resolution"
      end
    end
  end
end
