# frozen_string_literal: true

module ::TicketingSystem
  # Creates a ticket and its first message as one atomic unit.
  #
  # The atomicity is the point: a ticket with no opening message would render as
  # an empty thread that no one can reply to meaningfully, and the counters that
  # the list view reads are derived from that first message.
  class TicketCreator
    Result = Struct.new(:ticket, :message, keyword_init: true)

    def self.create!(user:, title:, body:, department: nil, priority: nil)
      new(user: user, title: title, body: body, department: department, priority: priority).create!
    end

    def initialize(user:, title:, body:, department: nil, priority: nil)
      @user = user
      @title = title.to_s.strip
      @body = body.to_s
      @department_param = department
      @priority_param = priority
    end

    def create!
      ensure_enabled!
      ensure_signed_in!
      RateLimiter.check_create!(@user)
      ensure_under_open_limit!

      department = resolve_department
      priority = resolve_priority(department)

      ticket = nil
      message = nil

      ActiveRecord::Base.transaction do
        ticket = Ticket.create!(
          title: @title,
          status: :open,
          priority: priority,
          requester_id: @user.id,
          department_id: department&.id,
          last_activity_at: Time.zone.now,
        )

        message = ticket.messages.create!(
          user_id: @user.id,
          body: @body,
          internal: false,
          staff: staff?,
        )

        ticket.message_count = 1
        ticket.staff_message_count = staff? ? 1 : 0

        # The author has obviously read their own ticket, so their counter starts
        # at zero and the other side's starts at one. Getting this backwards
        # would badge the requester's own new ticket as unread for themselves.
        ticket.requester_unread_count = 0
        ticket.staff_unread_count = staff? ? 0 : 1
        ticket.first_staff_reply_at = message.created_at if staff?
        ticket.last_activity_at = message.created_at
        ticket.save!

        Event.record!(ticket: ticket, actor: @user, kind: "created")
      end

      # Outside the transaction: a notification is a side effect on other users'
      # rows, and a failure there must not roll back a ticket the requester has
      # already been told exists.
      Notifier.ticket_created(ticket)

      Result.new(ticket: ticket, message: message)
    end

    private

    def staff?
      @staff ||= Permissions.staff?(@user)
    end

    def ensure_enabled!
      raise Errors::Disabled.new unless Permissions.enabled?
    end

    def ensure_signed_in!
      # `anonymous?` covers Discourse's anonymous-mode users, who have an id but
      # cannot own a ticket: their account is discarded when the session ends, so
      # the ticket would become unreachable.
      if @user.blank? || @user.id.blank? || @user.anonymous?
        raise Errors::Forbidden.new(:must_sign_in)
      end
    end

    def ensure_under_open_limit!
      limit = SiteSetting.ticketing_system_max_open_per_user.to_i
      return if limit <= 0
      return if staff? # staff triage on behalf of others; the cap is anti-abuse

      open_count = Ticket.for_requester(@user).active.count
      return if open_count < limit

      raise Errors::Conflict.new(:too_many_open_tickets, count: limit)
    end

    # Accepts an id, a slug, a Department, or nothing. An explicitly supplied
    # department that cannot be resolved is an error rather than a silent
    # fallback to the default — a ticket routed to the wrong queue is worse than
    # one the user is asked to re-submit.
    def resolve_department
      raw = @department_param
      return nil if raw.blank?

      department =
        case raw
        when Department then raw
        when Integer then Department.find_by(id: raw)
        else
          if raw.to_s.match?(/\A\d+\z/)
            Department.find_by(id: raw)
          else
            Department.find_by(slug: raw.to_s)
          end
        end

      raise Errors::Invalid.new(:unknown_department, http_status: 400, department: raw.to_s) if department.blank?
      raise Errors::Invalid.new(:department_disabled, http_status: 400, department: department.name) unless department.enabled

      department
    end

    def resolve_priority(department)
      # Only staff may pick a priority. A requester who cannot set it gets the
      # department's default, which is the same value they would have been shown.
      if @priority_param.present? && (staff? || SiteSetting.ticketing_system_allow_requester_priority)
        value = @priority_param.to_s
        unless Constants::PRIORITIES.key?(value.to_sym)
          raise Errors::Invalid.new(:invalid_priority, http_status: 400, priority: value)
        end
        return value.to_sym
      end

      return Constants::PRIORITIES.key(department.default_priority) if department.present?

      configured = SiteSetting.ticketing_system_default_priority.to_s
      return configured.to_sym if Constants::PRIORITIES.key?(configured.to_sym)

      :normal
    end
  end
end
