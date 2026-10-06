# frozen_string_literal: true

module ::TicketingSystem
  # Based on discourse/discourse-plugin-skeleton's lib/my_plugin_module/engine.rb,
  # with one deliberate difference: `engine_name` is an explicit lowercase slug
  # rather than PLUGIN_NAME.
  #
  # WHY NOT `engine_name PLUGIN_NAME`:
  #
  # In railties/lib/rails/engine.rb, `engine_name` is literally
  # `alias :engine_name :railtie_name` — a Rails-internal identifier, not a
  # user-facing label. `mount` derives its default route name from it
  # ("the :as option given to mount takes the engine_name as default"), and
  # railtie_name identifies the railtie inside Rails.
  #
  # PLUGIN_NAME happens to be a valid lowercase slug here, so
  # `engine_name PLUGIN_NAME` would work today. Setting it explicitly keeps a
  # Rails-internal identifier independent of a user-facing name — nothing depends
  # on the two matching, because the engine is mounted at an explicit `at:`, its
  # namespace comes from `isolate_namespace` (the MODULE, not the engine name),
  # and Discourse's plugin asset lookup uses the plugin DIRECTORY via
  # `DiscoursePluginRegistry.stylesheets_exists?(directory_name)`.
  #
  # There is deliberately no `config.paths["app/controllers"] << …` here. With
  # `isolate_namespace`, a controller's namespace comes from its DIRECTORY under
  # app/controllers: app/controllers/ticketing_system/tickets_controller.rb
  # defines TicketingSystem::TicketsController. Adding that subdirectory as a
  # second autoload root makes the same file reachable under two roots, which is
  # a Zeitwerk conflict rather than a fix.
  #
  # `config.autoload_paths << File.join(config.root, "lib")` is also omitted on
  # purpose. Every file under this plugin's lib/ is require_relative'd from
  # plugin.rb, so there is nothing to gain and one more way to get a
  # Zeitwerk::NameError on eager load.
  class Engine < ::Rails::Engine
    engine_name "ticketing_system"
    isolate_namespace TicketingSystem
  end
end
