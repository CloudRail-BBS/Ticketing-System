# frozen_string_literal: true

module ::TicketingSystem
  # Attachment policy and the two things that must be done with core's upload
  # tables rather than by hand.
  #
  # WHY THERE IS NO ticketing_system_uploads TABLE
  #
  # Core already owns uploads: it creates them, deduplicates them by SHA1, knows
  # where they are stored, and — the part that is easy to miss — rewrites their
  # URLs for `secure_uploads` forums. A plugin that stores its own `upload_id`
  # column gets the first three for free and silently loses the fourth. So the
  # association is `UploadReference`, which is core's own polymorphic join table,
  # and the payload is built by `UploadSerializer`.
  #
  # WHY THE PAYLOAD IS NOT A HAND-BUILT HASH
  #
  # `UploadSerializer#url` is:
  #
  #     object.for_site_setting ? object.url
  #                             : UrlHelper.cook_url(object.url, secure: SiteSetting.secure_uploads? && object.secure)
  #
  # A hash built by hand returns the raw storage path. On a forum with secure
  # uploads on, the browser is then handed a URL that the secure-uploads endpoint
  # never sees, and the attachment 404s — while the JSON looks perfectly
  # well-formed and the database row is correct. That is the failure mode this
  # whole module exists to avoid.
  #
  # WHY ATTACHMENTS DO NOT GET ORPHAN-CLEANED
  #
  # `app/jobs/scheduled/clean_up_uploads.rb` deletes uploads that nothing refers
  # to. Its exclusion list includes "uploads that are linked to anything but a
  # Post via UploadReference", and the SQL behind that is a LEFT JOIN on
  # `upload_references` with the condition `target_type != 'Post'` — so an upload
  # referenced by `TicketingSystem::Message` is excluded from the cleanup set
  # precisely BECAUSE its target is not a Post. The counter-intuitive consequence
  # is that a non-Post target type is what protects the file, and it is why this
  # must go through UploadReference rather than a bespoke column.
  #
  # KNOWN LIMITATION — secure_uploads forums
  #
  # On a forum with `secure_uploads` enabled, a ticket attachment IS marked
  # secure (neither `ticketing_system_message` nor `TicketingSystem::Message`
  # appears in `UploadSecurity::PUBLIC_TYPES` / `PUBLIC_UPLOAD_REFERENCE_TYPES`,
  # so it is not treated as public). It is then served through `/secure-uploads/`
  # — but `SecureUploadEndpointHelpers#check_secure_upload_permission` only
  # enforces a per-upload ACL when the upload has an `access_control_post_id`,
  # and a ticket attachment has no post. The check that remains is "must be
  # signed in".
  #
  # So: on such a forum the file is protected by being signed-in and by its URL
  # containing a SHA1 that cannot be guessed, but it is NOT scoped to the people
  # who can see the ticket, the way a private-message attachment is. Closing that
  # would mean teaching core's guardian about tickets, which is a larger change
  # than this plugin should make to core's upload path. It is documented rather
  # than papered over.
  module Attachments
    # A hard ceiling independent of the setting, so a typo in
    # /admin/site_settings cannot turn one message into an unbounded write.
    # 20 is well above any plausible support reply.
    MAX_ATTACHMENTS_CEILING = 20

    module_function

    def enabled?
      max_per_message.positive?
    end

    def max_per_message
      SiteSetting.ticketing_system_max_attachments.to_i.clamp(0, MAX_ATTACHMENTS_CEILING)
    end

    # Lower-cased, dot-stripped, deduplicated.
    #
    # The setting is a `list`, so `SiteSetting.x` hands back an Array — but a
    # value written by a rake task or a theme component can be the pipe-separated
    # string core stores underneath. Both are accepted, and normalising here
    # means the comparison below and the list sent to the client cannot disagree.
    def allowed_extensions
      raw = SiteSetting.ticketing_system_allowed_upload_extensions

      Array(raw)
        .flat_map { |value| value.to_s.split("|") }
        .map { |value| value.strip.downcase.delete_prefix(".") }
        .reject(&:empty?)
        .uniq
    end

    # Accepts `["3", "7"]`, `"3,7"` and `"3"`, because the client is not the only
    # caller — a rake task or a console session will hand this whatever it has.
    # Order is not preserved and duplicates are dropped: the reference table has
    # a unique index on (upload, target) and would reject the duplicate anyway.
    def normalize_ids(raw)
      Array(raw)
        .flat_map { |value| value.to_s.split(",") }
        .map(&:strip)
        .reject(&:empty?)
        .map(&:to_i)
        .reject(&:zero?)
        .uniq
    end

    # Validates the upload ids a client wants to attach to a message and returns
    # the ids to store. Raises one of Errors::* on any problem.
    #
    # Everything the client sent is re-checked against the database. The frontend
    # enforces the same rules to render a useful picker, but it is a convenience:
    # the ids arrive as request parameters and could be anything.
    def validate!(user:, upload_ids:)
      ids = normalize_ids(upload_ids)
      return [] if ids.empty?

      raise Errors::Forbidden.new(:attachments_disabled) unless enabled?

      if ids.length > max_per_message
        raise Errors::Invalid.new(:too_many_attachments, max: max_per_message)
      end

      uploads = Upload.where(id: ids).to_a

      # A well-formed id that names nothing is an error rather than a silently
      # dropped attachment: the user would see their reply posted without the
      # file and have no way to tell why.
      if uploads.length != ids.length
        raise Errors::Invalid.new(:unknown_attachment)
      end

      # The uploader must be the poster. Without this, anyone who learns (or
      # guesses) another user's upload id could staple that user's file to their
      # own message and then read it back through the ticket they now control.
      unless uploads.all? { |upload| upload.user_id == user.id }
        raise Errors::Forbidden.new(:attachment_not_owned)
      end

      allowed = allowed_extensions
      if allowed.any?
        rejected = uploads.map { |upload| upload.extension.to_s.downcase }.uniq - allowed
        if rejected.any?
          raise Errors::Invalid.new(
            :attachment_extension_not_allowed,
            extensions: rejected.sort.join(", "),
          )
        end
      end

      ids
    end

    # Points the uploads at the message. Idempotent, and the authority on what is
    # attached: passing a shorter list removes the rest, passing an empty list
    # removes all of them (see UploadReference.ensure_exist!).
    def attach!(target:, upload_ids:)
      ids = normalize_ids(upload_ids)
      UploadReference.ensure_exist!(upload_ids: ids, target: target)
    end

    # The serialised payload for a message's attachments.
    #
    # Sorted by id so a re-fetch returns them in a stable order: `has_many
    # :through` gives no ordering guarantee, and an attachment list that
    # reshuffles between renders looks like a bug to the person looking at it.
    def serialize(uploads)
      Array(uploads)
        .sort_by(&:id)
        .map { |upload| UploadSerializer.new(upload, root: false).as_json }
    end
  end
end
