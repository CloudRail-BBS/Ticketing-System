# frozen_string_literal: true

module ::TicketingSystem
  # One ticket, with its conversation and audit trail.
  #
  # This is the only place a singleton serialization happens, and it is done
  # through `serialize_one` in the controller rather than bare `serialize_data`:
  # `ApplicationController#serialize_data` branches on `respond_to?(:to_ary)`, and
  # for a singleton it calls `serializer.new(obj).as_json`, which AMS then wraps
  # in a root key derived from the class name. The result is
  # `{"ticket" => {"ticket" => {...}}}`, the list view keeps working (arrays skip
  # the root), and only the detail page breaks — reading `model.ticket.title`
  # yields undefined. `root: false` is the fix, and it is applied centrally.
  class TicketDetailSerializer < ::ApplicationSerializer
    include ::TicketingSystem::Serialization
    include ::TicketingSystem::TicketSerialization

    # Staff picker size. A department with more than this many staff is not
    # something a dropdown can serve anyway; the search box in the UI is the
    # answer beyond it.
    MAX_ASSIGNABLE_USERS = 200

    attributes :id,
               :display_number,
               :title,
               :status,
               :status_label,
               :priority,
               :priority_label,
               :department_id,
               :department,
               :requester_id,
               :requester,
               :assignee_id,
               :assignee,
               :message_count,
               :staff_message_count,
               :unread,
               :last_activity_at,
               :created_at,
               :updated_at,
               :resolved_at,
               :closed_at,
               :first_staff_reply_at,
               :sla,
               :can,
               :excerpt,
               :url,
               :messages,
               :events,
               :assignable_users

    # Internal notes are filtered HERE, at the query, not in the serializer. A
    # requester's payload must never contain the text of a note they cannot see,
    # even briefly — a client-side filter is a leak with extra steps.
    #
    # `root: false` on each nested serializer: without it every message would come
    # back as `{"message" => {...}}`, and the client would have to know that.
    def messages
      scope_relation = object.messages
      scope_relation = scope_relation.public_messages unless staff?
      scope_relation.map { |message| serialize(message, MessageSerializer) }
    end

    def events
      object.events.map { |event| serialize(event, EventSerializer) }
    end

    # Staff only. An empty array rather than nil for everyone else, so the client
    # can iterate without a guard.
    def assignable_users
      return [] unless staff?

      @assignable_users ||=
        begin
          ids = Permissions.staff_user_ids.first(MAX_ASSIGNABLE_USERS)
          # The current assignee may have left the staff group; without this they
          # would vanish from the picker while still being assigned, and the UI
          # would render an empty select on a ticket that is clearly assigned.
          ids |= [object.assignee_id] if object.assignee_id.present?
          User.where(id: ids).order(:username).map { |user| user_summary(user) }
        end
    end

    private

    def serialize(record, serializer_class)
      serializer_class.new(record, scope: scope, root: false).as_json
    end
  end
end
