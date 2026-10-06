# frozen_string_literal: true

module ::TicketingSystem
  # Aggregates for the admin overview tab.
  #
  # Staff-only rather than admin-only: the numbers describe the queue, and the
  # people who work the queue are exactly the people who should see whether it is
  # being worked. Department CRUD stays admin-only.
  class StatsController < BaseController
    before_action :ensure_staff!

    def show
      render json: { stats: Statistics.generate }
    end
  end
end
