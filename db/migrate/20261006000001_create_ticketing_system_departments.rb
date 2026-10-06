# frozen_string_literal: true

# The version bracket is REQUIRED on Rails 7.2+; a bare
# `class X < ActiveRecord::Migration` is rejected outright with
# "Directly inheriting from ActiveRecord::Migration is not supported", which
# aborts `rake db:migrate` and fails the whole bootstrap as
# `Pups::ExecError: ... db:migrate failed`.
#
# `[8.0]` rather than `[8.1]` on purpose. Core currently ships activerecord
# 8.1.4, and Rails keeps a compatibility class per release
# (`ActiveRecord::Migration::Compatibility::V8_0 < V8_1 < V8_2`), so a `[8.0]`
# migration is valid on 8.0, 8.1 and 8.2 alike. The DDL below uses no
# version-specific behaviour, so pinning to the newest number would only narrow
# the range of forums the plugin installs on, for no benefit.
class CreateTicketingSystemDepartments < ActiveRecord::Migration[8.0]
  def change
    create_table :ticketing_system_departments do |t|
      t.string :name, null: false
      t.string :slug, null: false
      t.string :description, null: false, default: ""
      t.integer :position, null: false, default: 0
      t.boolean :enabled, null: false, default: true

      # Name of the Discourse group that handles this department. Empty means
      # "any staff member", which is the sensible default for a single-queue
      # forum and keeps the plugin usable before any group is configured.
      t.string :staff_group_name, null: false, default: ""

      # Per-department SLA, in hours. Derived deadlines are computed at read time
      # from these — see ticketing_system_first_response_hours in settings.yml
      # for why there is no background job.
      t.integer :first_response_hours, null: false, default: 24
      t.integer :resolution_hours, null: false, default: 72

      # Integer, matching TicketingSystem::Constants::PRIORITIES.
      t.integer :default_priority, null: false, default: 1

      t.timestamps
    end

    # The slug is the public handle for a department and is used in API filters,
    # so it must be unique. Enforced in the database as well as the model: two
    # departments sharing a slug would make the filter ambiguous, and a
    # validation-only guarantee can be raced.
    add_index :ticketing_system_departments, :slug, unique: true
    add_index :ticketing_system_departments, %i[enabled position]
  end
end
