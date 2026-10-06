# frozen_string_literal: true

module Jobs
  # Overdue-ticket reminders. See TicketingSystem::SlaSweeper for the logic.
  #
  # A thin wrapper on purpose. Everything that decides what is overdue and who
  # hears about it lives in lib/, where it can be run from a console
  # (`TicketingSystem::SlaSweeper.call`) or a rake task without going through the
  # job queue — and where it can be read without knowing how Discourse's
  # scheduler works. This class exists only to put it on a timer.
  #
  # 15 minutes rather than daily: the point of a reminder is that it arrives
  # while the ticket is still worth rescuing. The job is cheap when nothing is
  # overdue (one indexed query) and `sla_notified_at` makes a repeat run a no-op,
  # so the frequency costs nothing but gives the reminder a useful latency.
  class TicketingSystemSlaSweep < ::Jobs::Scheduled
    every 15.minutes

    def execute(_args)
      result = TicketingSystem::SlaSweeper.call

      # Logged only when something happened. A line every 15 minutes saying
      # "0 notified" is how a log becomes unreadable.
      if result.notified.positive?
        Rails.logger.info(
          "[ticketing-system] SLA sweep notified staff about #{result.notified} overdue ticket(s)",
        )
      end

      result
    end
  end
end
