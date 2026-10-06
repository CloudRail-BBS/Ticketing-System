# frozen_string_literal: true

module ::TicketingSystem
  # Writes Discourse notifications for ticket events.
  #
  # WHY A PLUGIN-OWNED NOTIFICATION TYPE
  #
  # Core's `Notification.types` is a memoized `Enum`, and `Enum < Hash` — so a
  # plugin can add a member at runtime, which plugin.rb does:
  #
  #     Notification.types[:ticketing_system] = 5000
  #
  # The alternative would be reusing `Notification.types[:custom]` (14), but that
  # type is shared with every other plugin: whichever one registered a renderer
  # last would win, and all of them would render each other's notifications. A
  # dedicated type keeps the frontend renderer (`registerNotificationTypeRenderer`)
  # unambiguous.
  #
  # Notifications are a side effect, never a transaction participant: a failure
  # here is logged and swallowed. Rolling back a ticket because a badge could not
  # be written would be strictly worse than a missing badge.
  module Notifier
    TYPE_KEY = :ticketing_system

    module_function

    def ticket_created(ticket)
      return unless SiteSetting.ticketing_system_notify_staff

      recipients = staff_recipients(ticket) - [ticket.requester_id]
      deliver(recipients, ticket, event: "new_ticket", actor: ticket.requester)
    end

    def message_created(ticket, message)
      # Internal notes are staff bookkeeping. The requester cannot see them, so
      # notifying them would be a bug, and notifying the staff team for a note one
      # of them just wrote would make the shared inbox badge meaningless.
      return if message.internal?

      if message.staff
        return unless SiteSetting.ticketing_system_notify_requester
        deliver([ticket.requester_id], ticket, event: "staff_reply", actor: message.user)
      else
        return unless SiteSetting.ticketing_system_notify_staff
        recipients = staff_recipients(ticket) - [message.user_id]
        deliver(recipients, ticket, event: "requester_reply", actor: message.user)
      end
    end

    def assigned(ticket, actor, assignee)
      return if assignee.blank?
      return unless SiteSetting.ticketing_system_notify_assignee
      return if assignee.id == actor.id

      deliver([assignee.id], ticket, event: "assigned", actor: actor)
    end

    def status_changed(ticket, actor, _from, to)
      return unless SiteSetting.ticketing_system_notify_requester
      return if actor.id == ticket.requester_id
      # Only the states the requester cares about. A notification for every
      # internal shuffle (open -> in_progress) would train people to ignore them.
      return unless %w[resolved closed].include?(to)

      deliver(
        [ticket.requester_id],
        ticket,
        event: "status_changed",
        actor: actor,
        extra: {
          status: to,
        },
      )
    end

    # The department's own staff group when it has one, otherwise the plugin-wide
    # staff groups. The assignee is always included even if they are not in
    # either, because they are the one person who has explicitly taken the work.
    def staff_recipients(ticket)
      ids = ticket.department&.staff_user_ids
      ids = Permissions.staff_user_ids if ids.blank?
      (Array(ids) + [ticket.assignee_id]).compact.uniq
    end

    def deliver(user_ids, ticket, event:, actor: nil, extra: {})
      type = Notification.types[TYPE_KEY]

      if type.nil?
        # plugin.rb registers this in `after_initialize`. Reaching here means the
        # registration did not run, and every notification would be written with
        # a null type — loud, once per call, is the right amount of noise.
        Rails.logger.warn(
          "[ticketing-system] Notification type :#{TYPE_KEY} is not registered; skipping notifications",
        )
        return
      end

      data = {
        ticket_id: ticket.id,
        ticket_number: ticket.display_number,
        title: ticket.title,
        event: event.to_s,
        username: actor&.username,
        display_username: actor&.username,
      }.merge(extra)

      ids = Array(user_ids).compact.uniq.reject(&:zero?)
      return if ids.empty?

      ids.each do |user_id|
        # `topic_id` is deliberately nil, and core tolerates that in all three
        # places it matters. Checked against core rather than assumed, because
        # "notification created but never shown" is a silent failure:
        #
        #   * `Notification` declares `belongs_to :topic`, and in Rails 5+ that
        #     implies a presence validation — but `config.active_record
        #     .belongs_to_required_by_default = false` in config/application.rb
        #     turns it off, so a nil topic_id saves.
        #   * `scope :visible` is `LEFT JOIN topics … WHERE topics.id IS NULL OR
        #     topics.deleted_at IS NULL`. With a nil topic_id the first branch is
        #     true, so the row survives — and `scope :for_user_menu` is built on
        #     `visible`, so it does reach the user menu.
        #   * `after_commit :send_email` calls
        #     `NotificationEmailer.process_notification`, which looks up
        #     `Notification.types[type]` → `:ticketing_system` and then guards
        #     with `respond_to?`. `EmailUser` has no such method, so no email is
        #     attempted and nothing raises.
        #
        # There is also no `acting_user_id` column to set: `Notification#acting_user`
        # is an `attr_accessor`, and core fills it from `data[:username]` — which is
        # why `username` is in the payload above, and why the avatar renders.
        Notification.create!(
          user_id: user_id,
          notification_type: type,
          data: data.to_json,
        )
      rescue StandardError => e
        Rails.logger.warn(
          "[ticketing-system] could not notify user #{user_id} about ticket #{ticket.id}: #{e.class} #{e.message}",
        )
      end
    end
  end
end
