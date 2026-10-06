# frozen_string_literal: true

module ::TicketingSystem
  # Every authorisation decision in the plugin funnels through here.
  #
  # Two roles exist, and they are deliberately not "admin" and "everyone else":
  #
  #   requester  the user who opened the ticket. Sees only their own tickets and
  #              never sees internal notes.
  #   staff      members of the groups in `ticketing_system_staff_groups` (plus
  #              every admin). Sees every ticket, writes internal notes, and
  #              changes status / priority / assignee / department.
  #
  # Nothing here reads the current user from a global. Callers pass the user in,
  # which keeps the module usable from specs and from a serializer without a
  # `Guardian` round trip.
  #
  # THE `staff:` KEYWORD
  #
  # `staff?` costs one query. Serialising a 20-row page would otherwise run it
  # twenty times for the same user. Every predicate therefore accepts an
  # optional precomputed answer, and the controllers compute it once per request
  # and thread it through. `nil` means "I have not worked it out" — not false —
  # so an unset flag cannot be mistaken for a denial.
  module Permissions
    module_function

    def enabled?
      SiteSetting.ticketing_system_enabled
    end

    # `group_list` settings are stored as a pipe-separated string.
    def staff_group_names
      SiteSetting
        .ticketing_system_staff_groups
        .to_s
        .split("|")
        .map(&:strip)
        .reject(&:empty?)
        .uniq
    end

    def staff_group_ids
      names = staff_group_names
      return [] if names.empty?
      Group.where(name: names).pluck(:id)
    end

    # Everyone in the configured staff groups. Used for ticket notifications.
    # Admins who are not members of those groups are deliberately NOT added:
    # Discourse puts every admin and moderator in the `staff` group by default,
    # and a forum that points this setting at a narrower group has said who it
    # wants to hear from.
    def staff_user_ids
      group_ids = staff_group_ids
      return [] if group_ids.empty?
      GroupUser.where(group_id: group_ids).distinct.pluck(:user_id)
    end

    def staff?(user)
      return false if user.blank? || user.id.blank?
      # Admins are staff unconditionally. This is what keeps a forum whose
      # `ticketing_system_staff_groups` names a group that does not exist (or is
      # empty) from locking its own administrators out of the queue.
      return true if user.admin?

      group_ids = staff_group_ids
      return false if group_ids.empty?

      # Plain ActiveRecord rather than `user.in_any_groups?`: the query is
      # unambiguous, works on every Discourse version, and cannot be defeated by
      # a missing convenience method.
      GroupUser.where(user_id: user.id, group_id: group_ids).exists?
    end

    def can_view?(user, ticket, staff: nil)
      return false if user.blank? || ticket.blank?
      return true if resolve_staff(user, staff)
      ticket.requester_id == user.id
    end

    # A requester may reply while the ticket is not closed. Staff may always
    # reply — including on a closed ticket, which reopens it — because otherwise
    # a mis-closed ticket would be a dead end for everyone.
    def can_reply?(user, ticket, staff: nil)
      return false unless can_view?(user, ticket, staff: staff)
      return true if resolve_staff(user, staff)
      return false if ticket.closed?
      true
    end

    def can_write_internal_note?(user, ticket, staff: nil)
      return false unless SiteSetting.ticketing_system_allow_internal_notes
      return false unless can_view?(user, ticket, staff: staff)
      resolve_staff(user, staff)
    end

    def can_manage?(user, ticket, staff: nil)
      can_view?(user, ticket, staff: staff) && resolve_staff(user, staff)
    end

    def can_change_status?(user, ticket, staff: nil)
      return false unless can_view?(user, ticket, staff: staff)
      return true if resolve_staff(user, staff)

      # A requester's status power is limited to closing and reopening their own
      # ticket, and each half can be switched off independently.
      case ticket.status
      when "closed"
        SiteSetting.ticketing_system_allow_requester_reopen
      when "resolved"
        SiteSetting.ticketing_system_allow_requester_close ||
          SiteSetting.ticketing_system_allow_requester_reopen
      else
        SiteSetting.ticketing_system_allow_requester_close
      end
    end

    def can_change_priority?(user, ticket, staff: nil)
      return false unless can_view?(user, ticket, staff: staff)
      return true if resolve_staff(user, staff)
      SiteSetting.ticketing_system_allow_requester_priority && !ticket.closed?
    end

    def can_assign?(user)
      staff?(user)
    end

    def can_manage_departments?(user)
      return false if user.blank?
      user.admin?
    end

    # Which status values this user may move this ticket to. Returned as a list
    # so the frontend renders exactly the buttons the server will accept — a UI
    # that offers an action the controller then rejects is worse than no UI.
    def allowed_statuses(user, ticket, staff: nil)
      return Constants::STATUSES.keys.map(&:to_s) if resolve_staff(user, staff)
      return [] unless can_change_status?(user, ticket, staff: staff)

      case ticket.status
      when "closed" then %w[open]
      when "resolved" then %w[closed open]
      else %w[closed resolved]
      end
    end

    # The capability summary the client reads for one ticket.
    def ticket_capabilities(user, ticket, staff: nil)
      is_staff = resolve_staff(user, staff)

      {
        view: can_view?(user, ticket, staff: is_staff),
        reply: can_reply?(user, ticket, staff: is_staff),
        note: can_write_internal_note?(user, ticket, staff: is_staff),
        manage: can_manage?(user, ticket, staff: is_staff),
        change_status: can_change_status?(user, ticket, staff: is_staff),
        change_priority: can_change_priority?(user, ticket, staff: is_staff),
        assign: is_staff,
        statuses: allowed_statuses(user, ticket, staff: is_staff),
      }
    end

    # The payload the client reads from `current_user.ticketing_system`.
    #
    # Note this is exposed through `add_to_serializer(:current_user, …)`, which
    # generates an `include_ticketing_system?` guard returning false while the
    # plugin is disabled — so the frontend sees `undefined`, not an empty object,
    # when the plugin is off. Treat that as "disabled".
    def client_payload(user)
      return nil if user.blank?

      is_staff = staff?(user)

      {
        enabled: enabled?,
        staff: is_staff,
        admin: user.admin?,
        can_manage_departments: can_manage_departments?(user),
        can_assign: is_staff,
        can_write_internal_note: is_staff && SiteSetting.ticketing_system_allow_internal_notes,
        unread: unread_counts(user, staff: is_staff),
        limits: {
          title_min_length: SiteSetting.ticketing_system_title_min_length.to_i,
          title_max_length: SiteSetting.ticketing_system_title_max_length.to_i,
          body_max_length: SiteSetting.ticketing_system_body_max_length.to_i,
          max_open_per_user: SiteSetting.ticketing_system_max_open_per_user.to_i,
          page_size: SiteSetting.ticketing_system_list_page_size.to_i,
        },
        defaults: {
          priority: SiteSetting.ticketing_system_default_priority,
          first_response_hours: SiteSetting.ticketing_system_first_response_hours.to_i,
          resolution_hours: SiteSetting.ticketing_system_resolution_hours.to_i,
        },
      }
    end

    # Unread semantics are deliberately "shared inbox", not per-user:
    #
    #   requester_unread_count  cleared when the requester opens the ticket
    #   staff_unread_count      cleared when ANY staff member opens the ticket
    #
    # That is how a shared support mailbox behaves and it keeps the list query a
    # single indexed count. Per-staff read tracking would need a join table and a
    # LEFT JOIN on every list request; it is listed as future work in the README.
    def unread_counts(user, staff: nil)
      is_staff = resolve_staff(user, staff)

      requester_count =
        Ticket.where(requester_id: user.id).where("requester_unread_count > 0").count

      staff_count =
        if is_staff
          Ticket
            .where(status: Constants::ACTIVE_STATUS_VALUES)
            .where("staff_unread_count > 0")
            .count
        else
          0
        end

      { requester: requester_count, staff: staff_count, total: requester_count + staff_count }
    end

    # NOTE: there is deliberately no upload/attachment helper here. This version
    # stores no files — a ticket message is text only — so a client that asks
    # "which extensions may I attach?" would be asking a question the server
    # cannot act on. See the README's "Not implemented" section for what the
    # feature needs (an `UploadReference`-backed association and
    # `UploadSerializer`, not a hand-built hash, or `secure_uploads` forums
    # silently 403 their own attachments).

    # `nil` means "not computed yet" — distinct from `false`, which is a real
    # answer. Conflating the two would silently deny a staff member everything
    # the first time a caller forgot to pass the flag.
    def resolve_staff(user, override)
      return override unless override.nil?
      staff?(user)
    end
  end
end
