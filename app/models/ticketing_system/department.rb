# frozen_string_literal: true

module ::TicketingSystem
  # A department is a routing target: it decides who is expected to answer, how
  # fast, and what priority a new ticket starts at.
  #
  # WHY THIS FILE IS UNDER app/models AND NOT lib/
  #
  # It subclasses ActiveRecord::Base, which is Zeitwerk-owned from the main app.
  # Plugin activation runs inside `config/application.rb`'s body — before
  # `Rails.application.initialize!` builds the autoloader — so a
  # `require_relative` of this file from plugin.rb would evaluate the class body
  # while ActiveRecord::Base is not yet resolvable:
  #
  #   NameError: uninitialized constant ActiveRecord
  #
  # That surfaces as "You are unable to start Discourse due to errors in the
  # plugin at <dir>" followed by `exit 1`, which then fails the later
  # `rake db:migrate` step with a Pups::ExecError — one event, two symptoms.
  # Files under app/ load after boot, so the superclass resolves normally.
  class Department < ActiveRecord::Base
    # Rails derives the table name from the class name and IGNORES the module
    # namespace, so `TicketingSystem::Department` would look for `departments`.
    # Every model in this plugin therefore declares its table explicitly.
    self.table_name = "ticketing_system_departments"

    MAX_NAME_LENGTH = 80
    MAX_SLA_HOURS = 8760 # one year

    has_many :tickets,
             class_name: "TicketingSystem::Ticket",
             foreign_key: :department_id,
             dependent: :nullify,
             inverse_of: :department

    # Unicode-aware on purpose. `"技术支持".parameterize` returns "" — it strips
    # every non-ASCII character — so an ASCII-only slug rule would make a
    # Chinese-named department impossible to save. \p{L} and \p{N} accept any
    # script's letters and digits, which is exactly the set that is safe in a
    # query string once percent-encoded.
    SLUG_FORMAT = /\A[\p{L}\p{N}][\p{L}\p{N}_\-]*\z/

    validates :name, presence: true, length: { maximum: MAX_NAME_LENGTH }
    validates :description, length: { maximum: 500 }
    validates :slug,
              presence: true,
              length: {
                maximum: MAX_NAME_LENGTH,
              },
              uniqueness: {
                case_sensitive: false,
              },
              format: {
                with: SLUG_FORMAT,
                message: :invalid_slug,
              }
    validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :first_response_hours,
              numericality: {
                only_integer: true,
                greater_than: 0,
                less_than_or_equal_to: MAX_SLA_HOURS,
              }
    validates :resolution_hours,
              numericality: {
                only_integer: true,
                greater_than: 0,
                less_than_or_equal_to: MAX_SLA_HOURS,
              }
    validates :default_priority, inclusion: { in: Constants::PRIORITIES.values }

    # Only when the name changes. A department whose group was later renamed
    # keeps a dangling name, and validating unconditionally would then block an
    # unrelated edit (toggling `enabled`, say) until someone fixes the group —
    # turning a cosmetic drift into a stuck admin page.
    validate :staff_group_must_exist, if: :staff_group_name_changed?

    before_validation :assign_slug

    scope :enabled, -> { where(enabled: true) }
    scope :ordered, -> { order(position: :asc, id: :asc) }

    def self.slugify(value)
      candidate =
        value
          .to_s
          .strip
          .downcase
          .gsub(%r{[\s/\\]+}, "-")
          .gsub(/[^\p{L}\p{N}_\-]+/, "")
          .gsub(/-{2,}/, "-")
          .gsub(/\A[-_]+|[-_]+\z/, "")

      candidate.presence || "dept-#{SecureRandom.hex(3)}"
    end

    # The group that handles this department, or nil when the column is empty or
    # names a group that no longer exists.
    def staff_group
      return nil if staff_group_name.blank?
      @staff_group ||= Group.find_by(name: staff_group_name)
    end

    # Falls back to the plugin-wide staff groups. An empty per-department group
    # means "any staff member may take this", which is what a single-queue forum
    # wants and what keeps the plugin usable before any group is configured.
    def effective_staff_group_names
      return [staff_group_name] if staff_group.present?
      Permissions.staff_group_names
    end

    def default_priority_name
      Constants::PRIORITIES.key(default_priority).to_s
    end

    # Every user who should hear about a new ticket in this department.
    def staff_user_ids
      group_ids = Group.where(name: effective_staff_group_names).pluck(:id)
      return [] if group_ids.empty?
      GroupUser.where(group_id: group_ids).distinct.pluck(:user_id)
    end

    private

    def assign_slug
      return if slug.present?
      self.slug = self.class.slugify(name)
    end

    def staff_group_must_exist
      return if staff_group_name.blank?
      return if Group.exists?(name: staff_group_name)
      errors.add(:staff_group_name, :unknown_group, group: staff_group_name)
    end
  end
end
