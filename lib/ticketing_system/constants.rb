# frozen_string_literal: true

module ::TicketingSystem
  # Single source of truth for every enumerable value in the plugin.
  #
  # These hashes are consumed by `ActiveRecord::Base.enum` in the models, by the
  # serializers for i18n lookup keys, and by the controllers when validating
  # params — so a value that is valid in one place is valid everywhere.
  #
  # IMPORTANT: the integer values are a STORAGE CONTRACT. They are written to the
  # database, so reordering a hash or renumbering a value silently reinterprets
  # existing rows. Append new members with new numbers; never renumber.
  module Constants
    # Workflow: open -> in_progress -> pending -> resolved -> closed
    #   open        新工单，尚未有员工回复
    #   in_progress 员工已接手处理
    #   pending     等待用户补充信息（球在用户那边）
    #   resolved    已解决，等待用户确认或自动归档
    #   closed      已关闭，不可再回复（可由员工重开）
    STATUSES = { open: 0, in_progress: 1, pending: 2, resolved: 3, closed: 4 }.freeze

    # Statuses that still expect action. Used for the unread badge, the staff
    # inbox default scope and the "overdue" computation.
    ACTIVE_STATUS_NAMES = %w[open in_progress pending].freeze
    ACTIVE_STATUS_VALUES = ACTIVE_STATUS_NAMES.map { |name| STATUSES[name.to_sym] }.freeze

    # A requester may reopen a ticket in these states.
    REOPENABLE_STATUS_NAMES = %w[resolved closed].freeze

    PRIORITIES = { low: 0, normal: 1, high: 2, urgent: 3 }.freeze

    # Audit-trail kinds written to ticketing_system_events.
    #
    # These are strings, not integers: the table is an append-only log that is
    # read by humans and by the ticket timeline, so a readable value is worth
    # more than a byte. It also means adding a kind never touches existing rows.
    #
    # The last two are written by the scheduled jobs rather than by a person.
    # Every member needs a `ticketing_system.event.<kind>` line in
    # config/locales/server.{en,zh_CN}.yml; scripts/validate.py's enum check
    # enforces that, because `EventSerializer#kind_label` looks the label up
    # with `default: kind` — a missing translation degrades to the machine name
    # instead of a visible raw i18n key, so nobody would ever file that bug.
    EVENT_KINDS = %w[
      created
      replied
      internal_note
      status_changed
      priority_changed
      assignee_changed
      department_changed
      reopened
      closed
      sla_breached
      auto_closed
    ].freeze

    # Staff inbox scopes the API accepts.
    #
    # `mine` and `all` are the two the requester sees (`all` collapses to `mine`
    # for a non-staff caller); the rest are staff-only and are rejected rather
    # than silently downgraded, so a stale client cannot believe it is looking at
    # the whole queue while it is actually looking at one user's tickets.
    REQUESTER_SCOPES = %w[mine].freeze
    STAFF_SCOPES = %w[mine all unassigned assigned_to_me active].freeze
    ALL_SCOPES = (REQUESTER_SCOPES + STAFF_SCOPES).uniq.freeze

    # Sort orders the API accepts. Whitelisted rather than interpolated: a sort
    # parameter is user input that reaches SQL.
    SORT_ORDERS = {
      "recent" => { last_activity_at: :desc, id: :desc },
      "oldest" => { last_activity_at: :asc, id: :asc },
      "priority" => { priority: :desc, last_activity_at: :desc },
      "created" => { created_at: :desc, id: :desc },
    }.freeze
    DEFAULT_SORT = "recent"
  end
end
