# frozen_string_literal: true

module ::TicketingSystem
  # Domain errors, each carrying the HTTP status the controller should use.
  #
  # The alternative — `render_json_error` sprinkled through the service layer —
  # would put HTTP concerns in classes that also have to be usable from a rake
  # task or a spec. Raising one of these and mapping it in a single
  # `rescue_from` keeps the services transport-agnostic and guarantees every
  # rejection produces the same JSON envelope.
  #
  # THE KEYWORD IS `http_status:`, NOT `status:`, AND THAT IS LOAD-BEARING.
  #
  # `**options` below is the i18n interpolation hash: every key in it has to be a
  # placeholder in `ticketing_system.errors.<key>`. In this plugin `status` is a
  # first-class domain noun — a ticket has one, and "unknown status" is one of the
  # most common rejections — so a keyword named `status:` collides with the most
  # likely interpolation name. Ruby resolves that collision by keeping the LAST
  # value and emitting nothing but a parse warning:
  #
  #     # WRONG — one name, two meanings; the later value silently wins:
  #     Errors::Invalid.new(:invalid_status, status: 400, status: "bogus")
  #     #=> http_status is "bogus", not 400.
  #
  # The result was a 500 (`ArgumentError: invalid status`) instead of a 400, plus
  # a message rendering `[missing %{status} value]`, with nothing in the log
  # pointing at the cause. `scripts/check-ruby.rb` now turns that parse warning
  # into a failure, but the real fix is not to give one name two meanings.
  module Errors
    class Base < StandardError
      attr_reader :key, :http_status, :options

      def initialize(key, http_status: 422, **options)
        @key = key.to_s
        @http_status = http_status
        @options = options
        super(I18n.t("ticketing_system.errors.#{@key}", **options))
      end
    end

    class Disabled < Base
      def initialize(key = :disabled, **options)
        super(key, http_status: 404, **options)
      end
    end

    class Forbidden < Base
      def initialize(key = :forbidden, **options)
        super(key, http_status: 403, **options)
      end
    end

    class NotFound < Base
      def initialize(key = :not_found, **options)
        super(key, http_status: 404, **options)
      end
    end

    # 422 for a request that is well-formed but semantically impossible, 400 for
    # one whose parameters are simply wrong. Both reach the client as the same
    # JSON shape, so the distinction is for logs and specs.
    class Invalid < Base
      def initialize(key, http_status: 422, **options)
        super(key, http_status: http_status, **options)
      end
    end

    class BadRequest < Base
      def initialize(key = :bad_request, **options)
        super(key, http_status: 400, **options)
      end
    end

    # Used for "you already have too many open tickets" and similar state
    # conflicts — the request would have been fine a moment ago.
    class Conflict < Base
      def initialize(key, **options)
        super(key, http_status: 409, **options)
      end
    end
  end
end
