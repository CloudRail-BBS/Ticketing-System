# frozen_string_literal: true

module Jobs
  # Closes tickets left in `resolved`. See TicketingSystem::AutoCloser.
  #
  # Daily, because the grace period it enforces is measured in days: running it
  # more often would only make the same decision on a tighter clock, and running
  # it less often would let tickets sit past the period the setting promises.
  #
  # The wrapper is thin for the same reason as the SLA sweep: the logic is in
  # lib/ so it can be invoked directly and tested without the job system.
  class TicketingSystemAutoClose < ::Jobs::Scheduled
    every 1.day

    def execute(_args)
      closed = TicketingSystem::AutoCloser.call

      if closed.positive?
        Rails.logger.info(
          "[ticketing-system] auto-close moved #{closed} resolved ticket(s) to closed",
        )
      end

      closed
    end
  end
end
