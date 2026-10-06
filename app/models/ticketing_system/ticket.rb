# frozen_string_literal: true

module ::TicketingSystem
  # The ticket itself: metadata only. The conversation lives in Message, and
  # every state change is appended to Event.
  #
  # Counters (`message_count`, `staff_message_count`, `*_unread_count`) are
  # denormalised on purpose. The list view and the unread badge are the two
  # hottest reads in the plugin, and both would otherwise be an aggregate over
  # the messages table for every row on every page.
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

    validates :title, presence: true
    validate :title_length_within_settings

    scope :active, -> { where(status: Constants::ACTIVE_STATUS_VALUES) }
    scope :unassigned, -> { where(assignee_id: nil) }
    scope :assigned_to, ->(user) { where(assignee_id: user.is_a?(User) ? user.id : user) }
    scope :in_department, ->(department) { where(department_id: department.is_a?(Department) ? department.id : department) }
    scope :for_requester, ->(user) { where(requester_id: user.is_a?(User) ? user.id : user) }
    scope :with_priority, ->(value) { where(priority: Constants::PRIORITIES.fetch(value.to_s.to_sym)) }
    scope :with_status, ->(value) { where(status: Constants::STATUSES.fetch(value.to_s.to_sym)) }
    scope :with_staff_unread, -> { where("staff_unread_count > 0") }
    scope :with_requester_unread, -> { where("requester_unread_count > 0") }

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

    def unread_for_requester?
      requester_unread_count.to_i > 0
    end

    def unread_for_staff?
      staff_unread_count.to_i > 0
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

    # Derived at read time rather than scheduled.
    #
    # There is no background job in this plugin, so nothing can drift out of sync
    # with a settings change and nothing needs a catch-up pass after a deploy:
    # editing `ticketing_system_first_response_hours` immediately re-scores every
    # ticket. The cost is that the deadline is recomputed per serialisation,
    # which is a subtraction and two comparisons.
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
