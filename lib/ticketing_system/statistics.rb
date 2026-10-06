# frozen_string_literal: true

module ::TicketingSystem
  # Aggregates for the admin overview page.
  #
  # Every figure here is a single SQL aggregate. The one that looks expensive —
  # "how many tickets have breached their first-response deadline" — is answered
  # with a LEFT JOIN and a CASE rather than by loading tickets and computing the
  # SLA in Ruby, because the deadline depends on the department's own hours and
  # only the database can evaluate that for a whole table at once.
  class Statistics
    def self.generate
      new.generate
    end

    def generate
      {
        generated_at: Time.zone.now,
        totals: totals,
        by_status: by_status,
        by_priority: by_priority,
        by_department: by_department,
        first_response: first_response,
        activity: activity,
        load: staff_load,
      }
    end

    private

    def totals
      active = Ticket.active
      {
        all: Ticket.count,
        active: active.count,
        unassigned: active.where(assignee_id: nil).count,
        in_progress: Ticket.where(status: Constants::STATUSES[:in_progress]).count,
        overdue: overdue_scope.count,
      }
    end

    def by_status
      raw = Ticket.group(:status).count
      Constants::STATUSES.keys.index_with { |name| raw[Constants::STATUSES[name]].to_i }
    end

    def by_priority
      raw = Ticket.active.group(:priority).count
      Constants::PRIORITIES.keys.index_with { |name| raw[Constants::PRIORITIES[name]].to_i }
    end

    def by_department
      counts =
        Ticket
          .active
          .group(:department_id)
          .pluck(
            Arel.sql("department_id"),
            Arel.sql("COUNT(*)"),
            Arel.sql("COUNT(*) FILTER (WHERE assignee_id IS NULL)"),
          )
          .to_h { |department_id, total, unassigned| [department_id, [total, unassigned]] }

      overdue_by_department =
        overdue_scope.group(:department_id).count

      Department.ordered.map do |department|
        total, unassigned = counts[department.id] || [0, 0]
        {
          id: department.id,
          name: department.name,
          slug: department.slug,
          enabled: department.enabled,
          staff_group_name: department.staff_group_name,
          total: total,
          unassigned: unassigned,
          overdue: overdue_by_department[department.id].to_i,
        }
      end
    end

    # Time to first staff reply, measured only over tickets that actually got one.
    # Averaging in the unanswered ones as zero would make a badly-run queue look
    # fast.
    def first_response
      scope = Ticket.where.not(first_staff_reply_at: nil)
      sample = scope.count

      average =
        scope.pick(
          Arel.sql("AVG(EXTRACT(EPOCH FROM (first_staff_reply_at - created_at)))"),
        )

      # Percentile_cont is a Postgres aggregate; it returns an interval, so the
      # seconds conversion happens in SQL too.
      median =
        scope.pick(
          Arel.sql(
            "PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (first_staff_reply_at - created_at)))",
          ),
        )

      breached = overdue_scope.count + late_response_scope.count

      {
        sample_size: sample,
        average_seconds: average&.to_f&.round,
        median_seconds: median&.to_f&.round,
        breached: breached,
        on_time: [sample - late_response_scope.count, 0].max,
      }
    end

    def activity
      now = Time.zone.now
      {
        created_today: Ticket.where(created_at: now.beginning_of_day..).count,
        created_week: Ticket.where(created_at: 7.days.ago..).count,
        created_month: Ticket.where(created_at: 30.days.ago..).count,
        resolved_week: Ticket.where(resolved_at: 7.days.ago..).count,
        resolved_month: Ticket.where(resolved_at: 30.days.ago..).count,
        closed_month: Ticket.where(closed_at: 30.days.ago..).count,
      }
    end

    # "Who is carrying the queue." Only staff who currently hold at least one
    # open ticket appear, so the list stays short enough to read.
    def staff_load
      rows =
        Ticket
          .active
          .where.not(assignee_id: nil)
          .group(:assignee_id)
          .count
          .sort_by { |_user_id, count| -count }
          .first(10)

      users = User.where(id: rows.map(&:first)).index_by(&:id)

      rows.filter_map do |user_id, count|
        user = users[user_id]
        next if user.blank?
        {
          id: user.id,
          username: user.username,
          name: user.name,
          avatar_template: user.avatar_template,
          assigned: count,
        }
      end
    end

    # Active tickets whose first-response deadline has passed with no staff reply.
    #
    # The COALESCE is the whole reason this is raw SQL: the deadline is
    # `created_at + first_response_hours`, and the hours come from the department
    # when it has one and from the plugin setting otherwise. Expressing that in
    # ActiveRecord's DSL would mean either two queries or a N+1.
    def overdue_scope
      global_hours = SiteSetting.ticketing_system_first_response_hours.to_i

      Ticket
        .active
        .left_joins(:department)
        .where(first_staff_reply_at: nil)
        .where(
          "ticketing_system_tickets.created_at + " \
            "(COALESCE(ticketing_system_departments.first_response_hours, ?) * INTERVAL '1 hour') < ?",
          global_hours,
          Time.zone.now,
        )
    end

    # Tickets that did get a first reply, but later than the deadline allowed.
    def late_response_scope
      global_hours = SiteSetting.ticketing_system_first_response_hours.to_i

      Ticket
        .left_joins(:department)
        .where.not(first_staff_reply_at: nil)
        .where(
          "ticketing_system_tickets.first_staff_reply_at > " \
            "ticketing_system_tickets.created_at + " \
            "(COALESCE(ticketing_system_departments.first_response_hours, ?) * INTERVAL '1 hour')",
          global_hours,
        )
    end
  end
end
