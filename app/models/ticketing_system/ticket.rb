# frozen_string_literal: true

module ::TicketingSystem
  # The ticket itself: metadata only. The conversation lives in Message, and
  # every state change is appended to Event.
  #
  # Counters (`message_count`, `staff_message_count`) and the two per-side
  # message timestamps are denormalised on purpose. The list view and the unread
  # badge are the two hottest reads in the plugin, and both would otherwise be an
  # aggregate over the messages table for every row on every page.
  #
  # There is deliberately NO unread column here. Read state is per reader and
  # lives in ReadMarker; see that class for why, and `unread_for?` below for how
  # the two are combined. The per-side timestamps are what make that combination
  # a comparison of columns on a row already in hand rather than a scan.
  class Ticket < ActiveRecord::Base
    self.table_name = "ticketing_system_tickets"

    MAX_TITLE_LENGTH = 255

    # `enum` generates `#open?`, `#open!`, the `Ticket.open` scope and
    # `Ticket.statuses`. `validate: true` turns an out-of-range assignment into a
    # validation error instead of an ArgumentError, so an API caller sending
    # `status: "bogus"` gets a 422 with a readable message rather than a 500.
    #
    # The hashes are dup'd because `Constants` freezes them; Rails may normalise
    # the hash it is handed and a frozen input is a needless landmine.
    enum :status, Constants::STATUSES.dup, validate: true
    enum :priority, Constants::PRIORITIES.dup, validate: true

    belongs_to :requester, class_name: "User", foreign_key: :requester_id
    belongs_to :assignee, class_name: "User", foreign_key: :assignee_id, optional: true
    belongs_to :department,
               class_name: "TicketingSystem::Department",
               foreign_key: :department_id,
               optional: true

    has_many :messages,
             -> { order(:created_at, :id) },
             class_name: "TicketingSystem::Message",
             foreign_key: :ticket_id,
             dependent: :destroy,
             inverse_of: :ticket

    has_many :events,
             -> { order(:created_at, :id) },
             class_name: "TicketingSystem::Event",
             foreign_key: :ticket_id,
             dependent: :destroy,
             inverse_of: :ticket

    # `dependent: :destroy` alongside the database's `on_delete: :cascade`, the
    # same pairing messages and events use: the cascade is what keeps the table
    # honest if a ticket is ever deleted outside ActiveRecord, and the
    # association option is what keeps the behaviour visible here.
    has_many :read_markers,
             class_name: "TicketingSystem::ReadMarker",
             foreign_key: :ticket_id,
             dependent: :destroy,
             inverse_of: :ticket

    validates :title, presence: true
    validate :title_length_within_settings

    scope :active, -> { where(status: Constants::ACTIVE_STATUS_VALUES) }
    scope :unassigned, -> { where(assignee_id: nil) }
    scope :assigned_to, ->(user) { where(assignee_id: user.is_a?(User) ? user.id : user) }
    scope :in_department, ->(department) { where(department_id: department.is_a?(Department) ? department.id : department) }
    scope :for_requester, ->(user) { where(requester_id: user.is_a?(User) ? user.id : user) }
    scope :with_priority, ->(value) { where(priority: Constants::PRIORITIES.fetch(value.to_s.to_sym)) }
    scope :with_status, ->(value) { where(status: Constants::STATUSES.fetch(value.to_s.to_sym)) }

    # Tickets on which `user` has not seen the other side's latest message.
    #
    # Expressed as NOT EXISTS over the read markers rather than as a LEFT JOIN,
    # because that is the shape the index supports and it avoids the classic
    # LEFT JOIN trap: a join plus a `WHERE marker.user_id = ?` silently becomes
    # an inner join, and tickets with no marker at all — every ticket the reader
    # has never opened, which is the most common unread case — would vanish.
    #
    # The boundary column is chosen from a keyword, never from a parameter, so
    # nothing here is user input. `user.id` is a bind.
    def self.unread_for(user, staff:)
      boundary = staff ? "last_requester_message_at" : "last_staff_message_at"

      where.not(boundary => nil).where(
        "NOT EXISTS (SELECT 1 FROM #{ReadMarker.table_name} tsrm " \
          "WHERE tsrm.ticket_id = #{table_name}.id AND tsrm.user_id = ? " \
          "AND tsrm.last_read_at >= #{table_name}.#{boundary})",
        user.id,
      )
    end

    # `recent` is the default ordering everywhere: newest activity first, with
    # `id` as a tiebreaker so pagination cannot repeat or skip a row when two
    # tickets share a timestamp.
    scope :recent, -> { order(last_activity_at: :desc, id: :desc) }

    before_validation :ensure_last_activity_at

    def active?
      Constants::ACTIVE_STATUS_NAMES.include?(status)
    end

    def finished?
      !active?
    end

    # Is this viewer behind on this ticket?
    #
    # `last_read_at` is the reader's marker, or nil when they have never opened
    # the ticket — which means everything is unread for them, so the nil branch
    # answers true rather than false. Getting that backwards is the bug that
    # makes a brand new ticket show as read for the whole team.
    #
    # `viewer_is_staff` is passed in rather than derived: `Permissions.staff?`
    # costs a query, and a list page resolves it once for the whole page.
    def unread_for?(viewer_is_staff, last_read_at)
      boundary = viewer_is_staff ? last_requester_message_at : last_staff_message_at
      return false if boundary.blank?
      return true if last_read_at.blank?

      boundary > last_read_at
    end

    # The instant the OTHER side last spoke, which is the only thing a reader
    # can be behind on. Used by the unread badge and by the tests.
    def boundary_message_at(viewer_is_staff)
      viewer_is_staff ? last_requester_message_at : last_staff_message_at
    end

    # `#00042` — stable, human-quotable, and derived from the primary key rather
    # than a second sequence that could drift.
    def display_number
      return nil if id.blank?
      format("#%05d", id)
    end

    def first_response_hours
      department&.first_response_hours || SiteSetting.ticketing_system_first_response_hours.to_i
    end

    def resolution_hours
      department&.resolution_hours || SiteSetting.ticketing_system_resolution_hours.to_i
    end

    def first_response_due_at
      created_at + first_response_hours.hours
    end

    def resolution_due_at
      created_at + resolution_hours.hours
    end

    # Derived at read time, NOT stored.
    #
    # The deadline is a pure function of `created_at`, the department's hours and
    # the setting, so computing it here means a change to
    # `ticketing_system_first_response_hours` re-scores every ticket
    # immediately, with nothing to backfill and nothing that can drift out of
    # sync after a deploy. Storing a deadline would need a catch-up pass on every
    # settings change, and the pass would be wrong for the tickets it missed.
    #
    # The cost is that it is recomputed per serialisation, which is a subtraction
    # and two comparisons.
    #
    # NOTE: the SLA *sweep job* deliberately does not call this. It evaluates the
    # same rule as a SQL predicate over the whole table (see SlaSweeper), because
    # loading every open ticket into Ruby to compute a deadline the database can
    # compute is the difference between one query and thousands of them. The two
    # are kept in step by `SlaSweeper`'s own SQL using the identical COALESCE —
    # and `sla_state` below is the single definition of what "breached" means.
    def sla
      now = Time.zone.now
      first_due = first_response_due_at
      resolution_due = resolution_due_at

      {
        first_response_due_at: first_due,
        resolution_due_at: resolution_due,
        first_response_hours: first_response_hours,
        resolution_hours: resolution_hours,
        first_response_seconds: first_staff_reply_at && (first_staff_reply_at - created_at).round,
        first_response_state: sla_state(
          met_at: first_staff_reply_at,
          deadline: first_due,
          started_at: created_at,
          now: now,
        ),
        resolution_state: sla_state(
          met_at: resolved_at,
          deadline: resolution_due,
          started_at: created_at,
          now: now,
        ),
      }
    end

    def sla_breached?
      state = sla
      state[:first_response_state] == "breached" || state[:resolution_state] == "breached"
    end

    private

    def ensure_last_activity_at
      self.last_activity_at ||= Time.zone.now
    end

    def title_length_within_settings
      return if title.blank?

      length = title.to_s.length
      min = SiteSetting.ticketing_system_title_min_length.to_i
      max = [SiteSetting.ticketing_system_title_max_length.to_i, MAX_TITLE_LENGTH].min

      if length < min
        errors.add(:title, :too_short, count: min)
      elsif length > max
        errors.add(:title, :too_long, count: max)
      end
    end

    # "met"     finished inside the window
    # "breached" finished late, or the window has passed with nothing done
    # "due_soon" still open and less than 20% of the window remains
    # "on_track" still open with time to spare
    def sla_state(met_at:, deadline:, started_at:, now:)
      return "breached" if met_at && met_at > deadline
      return "met" if met_at
      return "breached" if now > deadline

      window = deadline - started_at
      return "on_track" if window <= 0
      return "due_soon" if (deadline - now) < (window * 0.2)

      "on_track"
    end
  end
end
