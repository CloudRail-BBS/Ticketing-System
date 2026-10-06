# frozen_string_literal: true

module ::TicketingSystem
  # Every state change a staff member can make, each one authorised, applied and
  # logged in the same shape.
  #
  # The four operations are grouped in one class because they share the same
  # three concerns — permission check, no-op detection, audit entry — and
  # splitting them would mean duplicating that skeleton four times and
  # eventually letting one copy drift.
  #
  # No-op detection matters more than it looks: the frontend sends the action the
  # user clicked, not a diff, so "close an already-closed ticket" is a normal
  # thing to receive. Writing an audit row for it would fill the timeline with
  # changes that did not happen.
  class TicketUpdater
    def self.change_status!(ticket:, actor:, status:)
      new(ticket: ticket, actor: actor).change_status!(status)
    end

    def self.change_priority!(ticket:, actor:, priority:)
      new(ticket: ticket, actor: actor).change_priority!(priority)
    end

    def self.assign!(ticket:, actor:, assignee:)
      new(ticket: ticket, actor: actor).assign!(assignee)
    end

    def self.change_department!(ticket:, actor:, department:)
      new(ticket: ticket, actor: actor).change_department!(department)
    end

    def initialize(ticket:, actor:)
      @ticket = ticket
      @actor = actor
    end

    def change_status!(raw_status)
      ensure_enabled!
      ensure_staff_or_permitted_status_change!

      status = raw_status.to_s
      unless Constants::STATUSES.key?(status.to_sym)
        raise Errors::Invalid.new(:invalid_status, http_status: 400, status: status)
      end

      # The same rule the client used to decide which buttons to render, applied
      # again on the server. The UI is a convenience, not a control.
      #
      # A different key from the `:status_change_not_allowed` raised by
      # `ensure_staff_or_permitted_status_change!` above, on purpose: that one
      # means "you may never change statuses", this one means "you may, but not
      # to this one". Telling a user who just moved a ticket successfully that
      # they "cannot change this ticket's status" is actively misleading.
      unless Permissions.allowed_statuses(@actor, @ticket).include?(status)
        raise Errors::Forbidden.new(:status_change_not_allowed_to, status: status)
      end

      return @ticket if @ticket.status == status

      previous = @ticket.status
      now = Time.zone.now

      @ticket.status = status
      case status
      when "resolved"
        @ticket.resolved_at = now
        @ticket.closed_at = nil
      when "closed"
        @ticket.closed_at = now
        @ticket.resolved_at ||= now
      else
        # Moving back to an active state clears both stamps. They are current
        # facts about the ticket, not history — the history is in the event log,
        # which is why clearing them loses nothing.
        @ticket.resolved_at = nil
        @ticket.closed_at = nil
      end
      @ticket.last_activity_at = now
      @ticket.save!

      Event.record!(
        ticket: @ticket,
        actor: @actor,
        kind: event_kind_for_status(previous, status),
        from: previous,
        to: status,
      )

      Notifier.status_changed(@ticket, @actor, previous, status)

      @ticket
    end

    def change_priority!(raw_priority)
      ensure_enabled!
      unless Permissions.can_change_priority?(@actor, @ticket)
        raise Errors::Forbidden.new(:priority_change_not_allowed)
      end

      priority = raw_priority.to_s
      unless Constants::PRIORITIES.key?(priority.to_sym)
        raise Errors::Invalid.new(:invalid_priority, http_status: 400, priority: priority)
      end

      return @ticket if @ticket.priority == priority

      previous = @ticket.priority
      @ticket.priority = priority
      @ticket.last_activity_at = Time.zone.now
      @ticket.save!

      Event.record!(
        ticket: @ticket,
        actor: @actor,
        kind: "priority_changed",
        from: previous,
        to: priority,
      )

      @ticket
    end

    def assign!(raw_assignee)
      ensure_enabled!
      raise Errors::Forbidden.new(:assign_not_allowed) unless Permissions.can_assign?(@actor)

      assignee = resolve_assignee(raw_assignee)
      return @ticket if @ticket.assignee_id == assignee&.id

      previous = @ticket.assignee&.username
      @ticket.assignee_id = assignee&.id
      @ticket.last_activity_at = Time.zone.now
      @ticket.save!

      Event.record!(
        ticket: @ticket,
        actor: @actor,
        kind: "assignee_changed",
        from: previous,
        to: assignee&.username,
      )

      Notifier.assigned(@ticket, @actor, assignee)

      @ticket
    end

    def change_department!(raw_department)
      ensure_enabled!
      raise Errors::Forbidden.new(:department_change_not_allowed) unless Permissions.can_manage?(@actor, @ticket)

      department = resolve_department(raw_department)
      return @ticket if @ticket.department_id == department&.id

      previous = @ticket.department&.name
      @ticket.department_id = department&.id
      @ticket.last_activity_at = Time.zone.now
      @ticket.save!

      Event.record!(
        ticket: @ticket,
        actor: @actor,
        kind: "department_changed",
        from: previous,
        to: department&.name,
      )

      @ticket
    end

    private

    def ensure_enabled!
      raise Errors::Disabled.new unless Permissions.enabled?
    end

    def ensure_staff_or_permitted_status_change!
      return if Permissions.can_change_status?(@actor, @ticket)
      raise Errors::Forbidden.new(:status_change_not_allowed)
    end

    # "closed"/"reopened" are what the timeline should read; everything else is a
    # plain status change. Keeping the distinction in one place means the
    # timeline labels stay consistent with the events written by
    # MessageCreator's automatic transitions.
    def event_kind_for_status(previous, status)
      return "closed" if status == "closed"
      if Constants::REOPENABLE_STATUS_NAMES.include?(previous) &&
           Constants::ACTIVE_STATUS_NAMES.include?(status)
        return "reopened"
      end
      "status_changed"
    end

    # nil, "" and "none" all mean unassign. "me" is the common case in the staff
    # UI and resolving it server-side avoids the client having to know its own
    # user id.
    def resolve_assignee(raw)
      case raw
      when nil, ""
        nil
      when User
        raw
      else
        value = raw.to_s.strip
        return nil if value.empty? || value == "none" || value == "unassign"
        return @actor if value == "me"

        user =
          if value.match?(/\A\d+\z/)
            User.find_by(id: value)
          else
            User.find_by(username: value)
          end

        raise Errors::Invalid.new(:unknown_assignee, http_status: 400, username: value) if user.blank?
        user
      end
    end

    def resolve_department(raw)
      return nil if raw.blank? || raw.to_s == "none"

      department =
        case raw
        when Department then raw
        else
          if raw.to_s.match?(/\A\d+\z/)
            Department.find_by(id: raw)
          else
            Department.find_by(slug: raw.to_s)
          end
        end

      raise Errors::Invalid.new(:unknown_department, http_status: 400, department: raw.to_s) if department.blank?
      department
    end
  end
end
