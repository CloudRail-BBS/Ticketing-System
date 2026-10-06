# frozen_string_literal: true

module ::TicketingSystem
  # One entry in a ticket's conversation: either a public reply or a staff-only
  # internal note.
  #
  # `body` (Markdown) and `cooked` (sanitised HTML) are both stored, exactly as
  # core's posts table does it. That buys the whole of Discourse's text pipeline
  # for free — Markdown, @mentions, emoji, onebox, and upload references — while
  # making the timeline a single query with no per-message Markdown pass.
  class Message < ActiveRecord::Base
    self.table_name = "ticketing_system_messages"

    belongs_to :ticket,
               class_name: "TicketingSystem::Ticket",
               foreign_key: :ticket_id,
               inverse_of: :messages
    belongs_to :user, class_name: "User", foreign_key: :user_id

    # Attachments, through core's own polymorphic join table.
    #
    # NOT a column on this model, and not a plugin-owned join table either: see
    # TicketingSystem::Attachments for the two things core does with uploads that
    # a hand-rolled association silently loses (the `secure_uploads` URL rewrite,
    # and the fact that a non-Post target type is what keeps the file out of the
    # orphan cleanup job).
    #
    # `dependent: :destroy` removes the REFERENCE when a message is deleted, not
    # the upload — which is core's behaviour for a deleted post too, and the
    # right one: the same upload may be referenced elsewhere.
    has_many :upload_references,
             class_name: "UploadReference",
             as: :target,
             dependent: :destroy

    has_many :uploads, through: :upload_references, source: :upload

    validates :body, presence: true
    validate :body_length_within_settings

    # `body_changed?` rather than an unconditional callback: re-cooking an
    # unchanged body on every save would be wasted work, and a future
    # `touch`-style update must not silently rewrite the rendered HTML.
    before_save :cook_body, if: :body_changed?

    scope :public_messages, -> { where(internal: false) }
    scope :internal_notes, -> { where(internal: true) }

    def excerpt(limit = 160)
      plain = cooked.to_s.gsub(/<[^>]*>/, " ").gsub(/\s+/, " ").strip
      return plain if plain.length <= limit
      "#{plain[0, limit]}…"
    end

    private

    def body_length_within_settings
      return if body.blank?

      max = SiteSetting.ticketing_system_body_max_length.to_i
      return if body.to_s.length <= max

      errors.add(:body, :too_long, count: max)
    end

    # PrettyText is core's Markdown pipeline, and it sanitises as it renders.
    # The rescue is not defensive padding: PrettyText can raise on pathological
    # input, and losing a reply the user already typed because the renderer
    # choked would be far worse than storing plainly-escaped text.
    def cook_body
      raw = body.to_s

      self.cooked =
        begin
          PrettyText.cook(raw)
        rescue StandardError => e
          Rails.logger.warn(
            "[ticketing-system] PrettyText.cook failed for ticket ##{ticket_id}: #{e.class} #{e.message}",
          )
          ERB::Util.html_escape(raw).gsub("\n", "<br>")
        end
    end
  end
end
