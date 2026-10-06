# frozen_string_literal: true

module ::TicketingSystem
  # Thin wrapper over core's RateLimiter, with one job: turn an exceeded limit
  # into this plugin's own error type.
  #
  # Core's `RateLimiter#performed!` raises `RateLimiter::LimitExceeded`, which
  # `ApplicationController` does rescue — but the rescue renders core's generic
  # message and the behaviour is a core implementation detail. Converting it here
  # means the API returns a ticket-specific, translated message that the frontend
  # can show next to the form, and that the plugin never depends on a rescue it
  # does not control.
  #
  # `performed!` does NOT increment the counter when it raises, so a rejected
  # attempt does not extend the ban.
  module RateLimiter
    # Raised for any client-caused rejection.
    #
    # `http_status` exists because `BaseController#render_ticketing_error` reads
    # it off whatever it rescued, by duck typing. This class is deliberately NOT
    # an `Errors::Base` subclass — it carries `retry_after` and is raised from
    # inside a rescue — but the controller handles both the same way, so it has
    # to answer to the same method name. Without this method the rescue itself
    # raised `NoMethodError: undefined method 'http_status'`, turning a rate limit
    # into a 500.
    class LimitExceeded < StandardError
      attr_reader :retry_after

      def initialize(message, retry_after: nil)
        super(message)
        @retry_after = retry_after
      end

      def http_status
        429
      end
    end

    CREATE_KEY = "ticketing_system_create"
    REPLY_KEY = "ticketing_system_reply"

    module_function

    def check_create!(user)
      limit = SiteSetting.ticketing_system_create_per_hour.to_i
      return if limit <= 0

      enforce!(
        user,
        CREATE_KEY,
        limit,
        1.hour.to_i,
        I18n.t(
          "ticketing_system.errors.create_rate_limited",
          count: limit,
        ),
      )
    end

    def check_reply!(user)
      limit = SiteSetting.ticketing_system_reply_per_hour.to_i
      return if limit <= 0

      enforce!(
        user,
        REPLY_KEY,
        limit,
        1.hour.to_i,
        I18n.t(
          "ticketing_system.errors.reply_rate_limited",
          count: limit,
        ),
      )
    end

    def enforce!(user, key, limit, seconds, message)
      limiter = ::RateLimiter.new(user, key, limit, seconds)
      limiter.performed!
    rescue ::RateLimiter::LimitExceeded
      raise LimitExceeded.new(message, retry_after: seconds)
    end
  end
end
