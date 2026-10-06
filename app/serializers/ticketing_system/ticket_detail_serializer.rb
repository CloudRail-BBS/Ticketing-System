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

    # "Who has seen this" stops being readable well before this. The cap exists
    # so one ticket on a large forum cannot put a thousand avatars in a payload.
    MAX_READERS = 50

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
               :assignable_users,
               :readers

    # Internal notes are filtered HERE, at the query, not in the serializer. A
    # requester's payload must never contain the text of a note they cannot see,
    # even briefly — a client-side filter is a leak with extra steps.
    #
    # `root: false` on each nested serializer: without it every message would come
    # back as `{"message" => {...}}`, and the client would have to know that.
    #
    # `includes(:uploads)` is what keeps the attachments to one extra query for
    # the whole thread rather than one per message: MessageSerializer#uploads
    # touches `object.uploads` for every message, and a twenty-message ticket
    # would otherwise issue twenty queries to render one page.
    def messages
      scope_relation = object.messages
      scope_relation = scope_relation.public_messages unless staff?
      scope_relation = scope_relation.includes(:uploads)
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

    # Staff only: who has opened this ticket, most recently read first.
    #
    # The requester is excluded on purpose. Their read state is already answered
    # by `unread` on the ticket, and the question this list exists to answer is
    # "has anyone on the team seen this yet" — which a row for the person who
    # opened it would only obscure.
    #
    # This is the read-marker table read the other way round: per ticket instead
    # of per reader. It is also why the unique index is (ticket_id, user_id)
    # rather than (user_id, ticket_id).
    def readers
      return [] unless staff?

      @readers ||=
        object
          .read_markers
          .includes(:user)
          .where.not(user_id: object.requester_id)
          .order(last_read_at: :desc)
          .limit(MAX_READERS)
          .filter_map do |marker|
            # A deleted user leaves a marker behind (there is no FK to `users`,
            # deliberately). Dropping the row is better than rendering a blank
            # avatar with no name.
            summary = user_summary(marker.user)
            next if summary.nil?

            summary.merge(last_read_at: marker.last_read_at)
          end
    end

    private

    def serialize(record, serializer_class)
      serializer_class.new(record, scope: scope, root: false).as_json
    end
  end
end
