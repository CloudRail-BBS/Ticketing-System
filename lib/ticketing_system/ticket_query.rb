# frozen_string_literal: true

module ::TicketingSystem
  # Turns request parameters into a filtered, paginated relation.
  #
  # Kept out of the controller because three different entry points need the same
  # query (the user list, the staff inbox, the admin statistics) and because the
  # visibility rule — a requester must never be able to widen the scope past
  # their own tickets — deserves to be enforced in exactly one place rather than
  # re-derived per action.
  class TicketQuery
    DEFAULT_PER_PAGE = 20
    MAX_PER_PAGE = 100
    MAX_SEARCH_LENGTH = 100

    Result = Struct.new(:tickets, :total, :page, :per_page, :pages, :scope, :sort, keyword_init: true)

    def initialize(user:, params: {})
      @user = user
      @staff = Permissions.staff?(user)
      @params = (params || {}).with_indifferent_access
    end

    def call
      base = relation
      per_page = resolved_per_page
      page = resolved_page
      total = base.except(:includes, :preload, :eager_load).count
      pages = total.zero? ? 1 : (total.to_f / per_page).ceil
      page = pages if page > pages

      tickets = base.offset((page - 1) * per_page).limit(per_page).to_a

      Result.new(
        tickets: tickets,
        total: total,
        page: page,
        per_page: per_page,
        pages: pages,
        scope: resolved_scope,
        sort: resolved_sort,
      )
    end

    # Exposed so the statistics endpoint can reuse the same visibility rules
    # without re-implementing them.
    def relation
      scope = apply_scope(base_relation)
      scope = apply_status_filter(scope)
      scope = apply_priority_filter(scope)
      scope = apply_department_filter(scope)
      scope = apply_assignee_filter(scope)
      scope = apply_requester_filter(scope)
      scope = apply_unread_filter(scope)
      scope = apply_search(scope)
      scope.order(Constants::SORT_ORDERS.fetch(resolved_sort))
    end

    private

    def base_relation
      # `includes` covers exactly the associations the serializers touch:
      # `department` for the SLA deadline, `requester` and `assignee` for the
      # display names. Without them a 20-row page is 60 extra queries.
      Ticket.includes(:department, :requester, :assignee)
    end

    # A requester's request for a staff scope is REJECTED, not silently narrowed
    # to their own tickets. Silently downgrading would let a stale or hostile
    # client believe it is looking at the whole queue while it is in fact looking
    # at one user's tickets — and any count it displays would be a lie.
    def apply_scope(scope)
      case resolved_scope
      when "mine" then scope.for_requester(@user)
      when "all" then scope
      when "unassigned" then scope.unassigned
      when "assigned_to_me" then scope.assigned_to(@user)
      when "active" then scope.active
      else scope.for_requester(@user)
      end
    end

    def resolved_scope
      @resolved_scope ||=
        begin
          requested = @params[:scope].presence || (@staff ? "all" : "mine")

          unless Constants::ALL_SCOPES.include?(requested)
            raise Errors::Invalid.new(:invalid_scope, http_status: 400, scope: requested)
          end

          if !@staff && !Constants::REQUESTER_SCOPES.include?(requested)
            raise Errors::Forbidden.new(:scope_requires_staff)
          end

          requested
        end
    end

    def resolved_sort
      @resolved_sort ||=
        begin
          requested = @params[:sort].presence || Constants::DEFAULT_SORT
          unless Constants::SORT_ORDERS.key?(requested)
            raise Errors::Invalid.new(:invalid_sort, http_status: 400, sort: requested)
          end
          requested
        end
    end

    def resolved_per_page
      configured = SiteSetting.ticketing_system_list_page_size.to_i
      requested = @params[:per_page].presence&.to_i
      value = requested || configured
      value = configured if value <= 0
      value.clamp(1, MAX_PER_PAGE)
    end

    def resolved_page
      value = @params[:page].presence&.to_i
      value.nil? || value < 1 ? 1 : value
    end

    # Comma-separated so the UI can ask for "open,in_progress" in one request.
    # Unknown members are rejected rather than dropped: a typo that silently
    # widens the result set is worse than an error.
    def apply_status_filter(scope)
      values = split_param(:status)
      return scope if values.empty?

      unknown = values - Constants::STATUSES.keys.map(&:to_s)
      raise Errors::Invalid.new(:invalid_status, http_status: 400, status: unknown.join(",")) if unknown.any?

      scope.where(status: values.map { |value| Constants::STATUSES.fetch(value.to_sym) })
    end

    def apply_priority_filter(scope)
      values = split_param(:priority)
      return scope if values.empty?

      unknown = values - Constants::PRIORITIES.keys.map(&:to_s)
      raise Errors::Invalid.new(:invalid_priority, http_status: 400, priority: unknown.join(",")) if unknown.any?

      scope.where(priority: values.map { |value| Constants::PRIORITIES.fetch(value.to_sym) })
    end

    def apply_department_filter(scope)
      raw = @params[:department].presence || @params[:department_id].presence
      return scope if raw.blank?

      if raw.to_s == "none"
        return scope.where(department_id: nil)
      end

      department =
        if raw.to_s.match?(/\A\d+\z/)
          Department.find_by(id: raw)
        else
          Department.find_by(slug: raw.to_s)
        end

      # An unknown department returns nothing rather than everything. Returning
      # everything would turn a typo into a silent data leak in a staff list.
      department ? scope.where(department_id: department.id) : scope.where("1 = 0")
    end

    def apply_assignee_filter(scope)
      raw = @params[:assignee].presence
      return scope if raw.blank?

      case raw.to_s
      when "none", "unassigned"
        scope.where(assignee_id: nil)
      when "me"
        scope.assigned_to(@user)
      else
        user = User.find_by(username: raw.to_s)
        user ? scope.assigned_to(user) : scope.where("1 = 0")
      end
    end

    def apply_requester_filter(scope)
      # Staff-only: without this a requester could probe whether a given user
      # exists and has tickets, which is information they have no business
      # seeing. The scope rule above already limits them to their own tickets,
      # so this filter could only ever narrow a result they cannot see.
      return scope unless @staff

      raw = @params[:requester].presence
      return scope if raw.blank?

      user = User.find_by(username: raw.to_s)
      user ? scope.for_requester(user) : scope.where("1 = 0")
    end

    def apply_unread_filter(scope)
      return scope unless ActiveModel::Type::Boolean.new.cast(@params[:unread])

      if @staff
        scope.with_staff_unread
      else
        scope.with_requester_unread
      end
    end

    # Search covers the four things a person actually types into a ticket search
    # box: part of a title, a ticket number, a username, or a phrase from the
    # conversation. Each is a separate indexed-or-cheap predicate; the whole
    # thing is bounded by the pagination that wraps it.
    def apply_search(scope)
      term = @params[:q].to_s.strip
      return scope if term.blank?

      term = term[0, MAX_SEARCH_LENGTH]
      pattern = "%#{ActiveRecord::Base.sanitize_sql_like(term)}%"

      conditions = ["title ILIKE :pattern"]

      # "#42", "42" and "42" inside a longer string all mean the same thing.
      number = term.delete("#").to_i
      conditions << "id = :number" if number.positive?

      # Staff may search by requester; a requester already only sees their own
      # tickets, so the predicate would be a no-op that costs a subquery.
      if @staff
        conditions << "requester_id IN (SELECT id FROM users WHERE username ILIKE :pattern)"
        conditions <<
          "id IN (SELECT ticket_id FROM ticketing_system_messages WHERE body ILIKE :pattern)"
      end

      scope.where(conditions.join(" OR "), pattern: pattern, number: number)
    end

    def split_param(key)
      @params[key].to_s.split(",").map(&:strip).reject(&:empty?).uniq
    end
  end
end
