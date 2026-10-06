# frozen_string_literal: true

module ::TicketingSystem
  # Shared helpers for the plugin's serializers.
  #
  # Lives in lib/ rather than app/serializers/ because it subclasses nothing —
  # it is a plain module, so it is safe to require from plugin.rb at boot, before
  # the autoloader exists. The serializers that include it are autoloaded later.
  module Serialization
    private

    # Discourse's `serialize_data` always passes the guardian as `scope`, so the
    # viewing user is available without threading it through as a second option.
    def current_user
      scope&.user
    end

    # `options[:staff]` is computed once per request by the controller.
    # Falling back to a query here would reintroduce the N+1 the keyword exists
    # to prevent, but it is still the right fallback: a wrong answer is worse
    # than a slow one, and a nil flag means the caller simply did not say.
    def staff?
      options[:staff].nil? ? Permissions.staff?(current_user) : options[:staff]
    end

    # The minimum a list row needs to render an avatar and a name. Kept
    # deliberately small: this is embedded once or twice per ticket, and the full
    # UserSerializer would drag a lot of unrelated payload along with it.
    def user_summary(user)
      return nil if user.blank?

      {
        id: user.id,
        username: user.username,
        name: user.name.presence || user.username,
        avatar_template: user.avatar_template,
        admin: user.admin?,
        moderator: user.moderator?,
      }
    end

    def department_summary(department)
      return nil if department.blank?

      {
        id: department.id,
        name: department.name,
        slug: department.slug,
        staff_group_name: department.staff_group_name,
        first_response_hours: department.first_response_hours,
        resolution_hours: department.resolution_hours,
      }
    end
  end
end
