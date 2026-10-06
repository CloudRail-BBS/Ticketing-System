# frozen_string_literal: true

module ::TicketingSystem
  # Filename must match the constant Zeitwerk derives from it, so `version.rb`
  # defines `Version` — not a bare `VERSION`, which Zeitwerk would reject.
  #
  # lib/ is not autoloaded today, but keeping every lib file self-consistent
  # means adding `config.autoload_paths << lib` later (as the official skeleton
  # does) cannot turn these into Zeitwerk::NameError on eager load.
  module Version
    VERSION = "1.0.0"
  end

  VERSION = Version::VERSION
end
