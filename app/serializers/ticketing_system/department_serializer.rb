# frozen_string_literal: true

module ::TicketingSystem
  # WHY THIS FILE IS UNDER app/serializers AND NOT lib/
  #
  # It subclasses ::ApplicationSerializer, which is Zeitwerk-loaded from the main
  # app. Plugin activation happens inside `config/application.rb`'s body — before
  # `Rails.application.initialize!` sets up the autoloader — so a
  # `require_relative` of this file from plugin.rb would evaluate the class body
  # while ApplicationSerializer is not yet resolvable:
  #
  #   NameError: uninitialized constant ApplicationSerializer
  #
  # That surfaces as "You are unable to start Discourse due to errors in the
  # plugin at <dir>" followed by `exit 1`, which then fails the later
  # `rake db:migrate` step. Files under app/ load after boot.
  #
  # `::ApplicationSerializer` rather than `ActiveModel::Serializer`: it is what
  # every serializer in Discourse extends and what
  # `ApplicationController#serialize_data` is written against. The base only adds
  # `embed :ids, include: true` and fragment-cache helpers, so for a serializer
  # with no declared associations the difference is invisible — which is exactly
  # why matching core matters. An invisible divergence cannot be debugged by
  # reading this file.
  #
  # Deliberately no `ticket_count`. An aggregate per department would be an N+1 on
  # a picker that renders on every page load; the admin overview gets its counts
  # from `Statistics`, which computes all of them in one pass.
  class DepartmentSerializer < ::ApplicationSerializer
    attributes :id,
               :name,
               :slug,
               :description,
               :position,
               :enabled,
               :staff_group_name,
               :first_response_hours,
               :resolution_hours,
               :default_priority

    # Overrides the column reader on purpose. The column is an integer; every
    # consumer — the create form, the filter chips, the admin table — wants the
    # name, and translating it here means no client has to know the mapping.
    def default_priority
      object.default_priority_name
    end
  end
end
