# frozen_string_literal: true

module ::TicketingSystem
  # Everything the frontend needs that is not ticket data: the department picker,
  # the status and priority vocabularies with their labels, the current user's
  # capabilities, and the unread counters.
  #
  # Fetched once per session and cached client-side, which is why the ticket list
  # response does not repeat any of it. The vocabularies are translated server-side
  # so the client never hardcodes the status names — adding a status becomes a
  # one-file change instead of a two-language one.
  class MetaController < BaseController
    def show
      render json: {
        departments: serialize_many(enabled_departments, DepartmentSerializer),
        statuses: vocabulary(Constants::STATUSES, "status"),
        priorities: vocabulary(Constants::PRIORITIES, "priority"),
        scopes: available_scopes,
        capabilities: Permissions.client_payload(current_user),
        unread: Permissions.unread_counts(current_user, staff: staff?),
        defaults: {
          priority: SiteSetting.ticketing_system_default_priority,
        },
      }
    end

    private

    def enabled_departments
      Department.enabled.ordered.to_a
    end

    # `statuses` and `priorities` are ordered hashes whose insertion order is the
    # workflow order, so the UI can render them as-is.
    def vocabulary(hash, i18n_namespace)
      hash.keys.map do |name|
        {
          id: name.to_s,
          label: I18n.t("ticketing_system.#{i18n_namespace}.#{name}"),
        }
      end
    end

    # A requester is offered exactly one scope. Advertising the staff scopes and
    # then rejecting them would be a worse experience than not showing them — and
    # the server rejects them rather than narrowing them, so the client must not
    # believe it can ask.
    def available_scopes
      return Constants::STAFF_SCOPES if staff?

      Constants::REQUESTER_SCOPES
    end
  end
end
