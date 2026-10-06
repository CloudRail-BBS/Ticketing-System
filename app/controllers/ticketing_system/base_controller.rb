# frozen_string_literal: true

module ::TicketingSystem
  # Shared behaviour for every JSON endpoint in the plugin.
  #
  # Two things are centralised here rather than repeated in eight controllers:
  # the guards (plugin enabled, signed in) and the error mapping. A `rescue_from`
  # in one base class is what guarantees every rejection produces the same JSON
  # envelope, so the frontend has exactly one error shape to handle.
  #
  # Note `skip_before_action :check_xhr` is NOT here. Every action in this tree is
  # a JSON endpoint that the Ember app calls with `discourse/lib/ajax`, which sets
  # `X-Requested-With` and the CSRF token. Keeping both core filters on means a
  # cross-site POST cannot reach a mutating action.
  class BaseController < ::ApplicationController
    requires_plugin PLUGIN_NAME

    before_action :ensure_ticketing_system_enabled
    before_action :ensure_signed_in

    rescue_from ::TicketingSystem::Errors::Base, with: :render_ticketing_error
    rescue_from ::TicketingSystem::RateLimiter::LimitExceeded, with: :render_ticketing_error
    rescue_from ActiveRecord::RecordInvalid, with: :render_record_invalid

    private

    # `requires_plugin` guarantees the plugin is LOADED. It does not consult the
    # plugin's `enabled_site_setting`, so the switch has to be checked explicitly.
    def ensure_ticketing_system_enabled
      raise Discourse::NotFound unless Permissions.enabled?
    end

    def ensure_signed_in
      # Anonymous-mode users have an id but their account is discarded with the
      # session, so a ticket they opened would become unreachable. Treated as
      # signed out.
      raise Discourse::InvalidAccess.new if current_user.blank? || current_user.anonymous?
    end

    # Computed once per request and threaded into every serializer.
    #
    # `Permissions.staff?` costs a query, and serialising a page of tickets calls
    # it per row unless the answer is passed along. Memoised here rather than in
    # the module so the value cannot outlive the request that produced it.
    def staff?
      @staff = Permissions.staff?(current_user) if @staff.nil?
      @staff
    end

    def admin?
      @admin = current_user&.admin? if @admin.nil?
      @admin
    end

    def ensure_admin!
      raise Discourse::InvalidAccess.new unless admin?
    end

    def ensure_staff!
      raise Errors::Forbidden.new(:staff_only) unless staff?
    end

    # `serialize_data` adds a root key for SINGLETONS only.
    #
    # `ApplicationController#serialize_data` branches on `respond_to?(:to_ary)`;
    # for a single object it calls `serializer.new(obj).as_json`, and AMS then
    # wraps that in a root named after the serializer's class. The obvious call
    # therefore double-wraps — `{"ticket" => {"ticket" => {...}}}` — and because
    # arrays skip the root, the list page keeps working while only the detail page
    # breaks, reading undefined for every field. Passing `root: false` is the fix,
    # applied here so no call site can forget it.
    def serialize_one(object, serializer, **options)
      serialize_data(object, serializer, options.merge(root: false))
    end

    def serialize_many(objects, serializer, **options)
      serialize_data(objects.to_a, serializer, options.merge(root: false))
    end

    def find_ticket!(raw_id)
      ticket = Ticket.find_by(id: raw_id)
      raise Errors::NotFound.new(:ticket_not_found) if ticket.blank?
      raise Errors::Forbidden.new unless Permissions.can_view?(current_user, ticket, staff: staff?)
      ticket
    end

    # Opening a ticket clears the reader's unread counter.
    #
    # `update_columns` on purpose: it skips `updated_at` AND leaves
    # `last_activity_at` alone. Bumping either would make simply reading a ticket
    # jump it to the top of everyone's queue, which is the opposite of what a
    # triage list should do.
    def mark_read!(ticket)
      now = Time.zone.now

      if staff?
        ticket.update_columns(staff_unread_count: 0, staff_last_read_at: now)
      else
        ticket.update_columns(requester_unread_count: 0, requester_last_read_at: now)
      end
    end

    # One query for the whole page instead of one per row.
    #
    # `DISTINCT ON` is Postgres-specific and Discourse is Postgres-only; the
    # alternative is a correlated subquery per ticket or a window function, both
    # of which are more code for the same answer. The ORDER BY must lead with the
    # DISTINCT ON expression, which is why `ticket_id` comes first and
    # `created_at` second.
    def excerpts_for(tickets)
      ids = tickets.map(&:id)
      return {} if ids.empty?

      rows =
        Message
          .where(ticket_id: ids, internal: false)
          .select("DISTINCT ON (ticket_id) ticket_id, cooked")
          .order("ticket_id ASC, created_at ASC, id ASC")

      rows.each_with_object({}) do |message, result|
        result[message.ticket_id] = Message.new(cooked: message.cooked).excerpt
      end
    end

    # One mapper for two unrelated exception trees, by duck typing: both
    # `Errors::Base` and `RateLimiter::LimitExceeded` answer to `http_status` and
    # `message`. That is the whole contract, and it is why neither class has to
    # inherit from the other.
    def render_ticketing_error(error)
      render_json_error(error.message, status: error.http_status)
    end

    # Validation failures carry the model's own messages, which are already
    # translated. Passing them through is more useful than a generic 422.
    def render_record_invalid(error)
      render_json_error(error.record.errors.full_messages.join(" "), status: 422)
    end
  end
end
