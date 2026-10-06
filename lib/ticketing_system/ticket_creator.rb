# frozen_string_literal: true

module ::TicketingSystem
  # Creates a ticket and its first message as one atomic unit.
  #
  # The atomicity is the point: a ticket with no opening message would render as
  # an empty thread that no one can reply to meaningfully, and the counters that
  # the list view reads are derived from that first message.
  class TicketCreator
    Result = Struct.new(:ticket, :message, keyword_init: true)

    def self.create!(user:, title:, body:, department: nil, priority: nil, upload_ids: nil)
      new(
        user: user,
        title: title,
        body: body,
        department: department,
        priority: priority,
        upload_ids: upload_ids,
      ).create!
    end

    def initialize(user:, title:, body:, department: nil, priority: nil, upload_ids: nil)
      @user = user
      @title = title.to_s.strip
      @body = body.to_s
      @department_param = department
      @priority_param = priority
      @upload_ids = upload_ids
    end

    def create!
      ensure_enabled!
      ensure_signed_in!
      RateLimiter.check_create!(@user)
      ensure_under_open_limit!

      # Validated before the transaction, for the same reasons as in
      # MessageCreator: nothing half-written on rejection, and no write
      # transaction held open across a handful of reads.
      attachment_ids = Attachments.validate!(user: @user, upload_ids: @upload_ids)

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

        # Which side the opening message counts as is what decides who starts out
        # behind, and the two cases are genuinely different:
        #
        #   a requester's ticket is unread for EVERY staff member until each of
        #   them opens it — there is no per-ticket counter to set, because the
        #   absence of a read marker already says "this person has not looked";
        #
        #   a staff-created ticket (staff opening one on someone's behalf) is
        #   unread for its requester, and its first-response clock has already
        #   stopped.
        if staff?
          ticket.last_staff_message_at = message.created_at
          ticket.first_staff_reply_at = message.created_at
        else
          ticket.last_requester_message_at = message.created_at
        end

        ticket.last_activity_at = message.created_at
        ticket.save!

        Attachments.attach!(target: message, upload_ids: attachment_ids)

        # The author has obviously read the ticket they just opened. Without this
        # row the requester would be badged for their own new ticket the moment
        # anyone else replied — and, on a staff-created ticket, the staff author
        # would be badged for their own opening message.
        ReadMarker.mark_read!(ticket: ticket, user: @user, at: message.created_at)

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
