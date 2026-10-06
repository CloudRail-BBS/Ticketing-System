# name: ticketing-system
# about: A self-contained ticket (work order) system with departments, priorities, assignment, internal notes and staff inbox.
# version: 1.0.0
# authors: CloudRail BBS
# url: https://github.com/CloudRail-BBS/Ticketing-System
# required_version: 3.2.0
# transpile_js: true

# frozen_string_literal: true

# THE NAME AND DIRECTORY MUST BE LOWERCASE, AND THE DIRECTORY IS WHAT COUNTS.

# The repo is named `Ticketing-System`; the plugin and its install directory are
# `ticketing-system`. Core's stylesheet route constrains the name to lowercase:

#     # config/routes.rb
#     get "stylesheets/:name" => "stylesheets#show",
#         constraints: { name: /[-a-z0-9_]+/, format: "css" }, format: true

# The <link> Discourse emits uses the plugin DIRECTORY name, so a directory
# named `Ticketing-System` produces /stylesheets/Ticketing-System_<digest>.css,
# that constraint never matches, and the request 404s. The controller is never
# entered. Everything else still looks healthy: the compile succeeds, the
# stylesheet_cache row exists with the exact requested digest, the <link> is
# emitted, and every other plugin serves fine. The only symptom is a page with
# no styles at all plus a console message about MIME type 'text/html'.

# `git clone <url>` with no destination derives the directory from the repo name,
# which here would be `Ticketing-System`. ALWAYS pin it:
#     git clone https://github.com/CloudRail-BBS/Ticketing-System.git ticketing-system
# and in containers/app.yml:
#     - exec:
#         cd: $home/plugins
#         cmd:
#           - git clone https://github.com/CloudRail-BBS/Ticketing-System.git ticketing-system

# DO NOT add a line to this file whose stripped content is just "#".
# Plugin::Metadata#parse_line has no nil guard: for such a line it computes
# attribute = nil and then calls nil.strip, raising NoMethodError, which aborts
# the whole boot before any plugin activates — with a backtrace pointing at core
# and naming no plugin. Blank lines are safe (parse_line returns true for them),
# so paragraph breaks here are blank lines, never "#" rules. This applies to
# plugin.rb only; a bare "#" in any other .rb file is an ordinary comment.

# PLUGIN_NAME must equal both the `# name:` above and the installed directory
# name; all three are `ticketing-system` here. Core keys two lookups off two
# different values: `AdminPluginSerializer#id` returns `directory_name` (the
# DIRECTORY), which is what the admin plugin list, `api.setAdminPluginIcon` and
# `api.addAdminPluginConfigurationNav` match against, while
# `Discourse.plugins_by_name` is keyed by the plugin name and is what
# `add_admin_route`'s location resolves through. Aligning all three makes that
# whole class of bug impossible.

# PLUGIN_NAME is NOT provided by core: `Plugin::Instance#activate!` runs
# `instance_eval File.read(path), path` and nothing in lib/plugin/instance.rb
# defines it. Undefined, `requires_plugin PLUGIN_NAME` raises NameError, which
# `Plugin.initialization_guard` catches, prints "You are unable to start
# Discourse due to errors in the plugin at <dir>" and calls `exit 1` — the same
# `exit 1` that then fails the following `rake db:migrate` step.

# It must be defined BEFORE the engine is required, because engine.rb reads
# PLUGIN_NAME while its class body is evaluated.
module ::TicketingSystem
  PLUGIN_NAME = "ticketing-system"
end

# lib/ is not autoloaded, so these must be required explicitly. Nothing under
# app/ may be required here: plugin activation happens inside
# `config/application.rb`'s body, i.e. before `Rails.application.initialize!`
# creates the autoloader, so a file subclassing a Zeitwerk-owned class
# (ApplicationSerializer, ApplicationController, ActiveRecord::Base) would raise
# `NameError: uninitialized constant` during boot. Models and serializers live
# under app/ and load after boot.
require_relative "lib/ticketing_system/version"
require_relative "lib/ticketing_system/constants"
require_relative "lib/ticketing_system/errors"
require_relative "lib/ticketing_system/permissions"
require_relative "lib/ticketing_system/serialization"
require_relative "lib/ticketing_system/ticket_serialization"
require_relative "lib/ticketing_system/rate_limiter"
require_relative "lib/ticketing_system/notifier"
require_relative "lib/ticketing_system/ticket_query"
require_relative "lib/ticketing_system/ticket_creator"
require_relative "lib/ticketing_system/message_creator"
require_relative "lib/ticketing_system/ticket_updater"
require_relative "lib/ticketing_system/statistics"
require_relative "lib/ticketing_system/engine"

enabled_site_setting :ticketing_system_enabled

# The plugin serves its own top-level page, so its stylesheets have to be
# registered explicitly — nothing under assets/stylesheets is auto-included.
# `Plugin::Instance#assets` and `DiscoursePluginRegistry.stylesheets` are only
# written by this call, so an unregistered stylesheet silently does nothing.

# Both files go to the FRONTEND bundle, including the "admin" one. The usual
# `:admin` target would be wrong here: `:admin` puts a stylesheet in the admin
# bundle, which only loads on /admin routes. This plugin's management page is a
# route on the plugin's own frontend route map (`ticketing-system.admin`, at
# /tickets/admin), so a stylesheet loaded only under /admin would never reach the
# page that needs it — the page would render, unstyled, with nothing in the log.
register_asset "stylesheets/ticketing-system.scss"
register_asset "stylesheets/ticketing-system-admin.scss"

after_initialize do
  # Registers a plugin-owned notification type.

  # Core's `Notification.types` is a memoized `Enum`, and `Enum < Hash`, so a
  # plain `[]=` adds a member at runtime. This is how the notification shows up
  # with a real name instead of falling through to the generic `custom` type
  # (14), which is shared with every other plugin and must not be hijacked.

  # 5000 is deliberately far outside core's reserved ranges (core itself uses
  # 1-45, then 800-802 for discourse-follow, 900 for discourse-circles and 1000
  # for the voice plugin). Values are persisted as integers in the notifications
  # table, so the number is a storage contract, not a label: never change it
  # once tickets have produced notifications.
  Notification.types[:ticketing_system] = 5000

  # Exposes per-user unread counters to the client. `add_to_serializer(:site, …)`
  # would be wrong here: the site payload is shared between users and cached for
  # anonymous visitors, whereas these counters are per-user.

  # Note `add_to_serializer` generates an `include_<attr>?` method that returns
  # false while the plugin is disabled, so the key is ABSENT rather than empty —
  # the frontend must treat `undefined` as "plugin off", not as zero.
  add_to_serializer(:current_user, :ticketing_system) do
    ::TicketingSystem::Permissions.client_payload(scope.user)
  end

  # `use_new_show_route: true` sets `full_location` to `adminPlugins.show`, a
  # CORE route, so the link on /admin/plugins always resolves. With `false` the
  # location becomes `adminPlugins.<slug>`, which exists only if the plugin
  # mounts it — and the legacy mount point is dead.

  # The location must be the plugin's name (which equals the directory name),
  # because core loads the page via
  # `Discourse.plugins_by_name[params[:plugin_id]]`.

  # Referenced through the absolute constant rather than a bare PLUGIN_NAME:
  # plugin.rb is evaluated as a string, so its top-level cref is Object, where a
  # bare PLUGIN_NAME would resolve to ::PLUGIN_NAME and miss TicketingSystem::.
  add_admin_route(
    "ticketing_system.admin.title",
    ::TicketingSystem::PLUGIN_NAME,
    use_new_show_route: true,
  )
end
