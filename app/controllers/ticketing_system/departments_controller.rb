# frozen_string_literal: true

module ::TicketingSystem
  # Department CRUD for the admin tab.
  #
  # Reading is staff-only (staff need the full list, including disabled
  # departments, to route a ticket correctly); writing is admin-only. The
  # asymmetry is deliberate: a department is forum-wide configuration, and letting
  # every staff member create one would turn a routing table into a free-for-all.
  class DepartmentsController < BaseController
    before_action :ensure_staff!, only: :index
    before_action :ensure_admin!, only: %i[create update destroy]
    before_action :load_department, only: %i[update destroy]

    def index
      render json: { departments: serialize_many(Department.ordered.to_a, DepartmentSerializer) }
    end

    def create
      department = Department.new(department_params)
      department.save!

      render json: { department: serialize_one(department, DepartmentSerializer) }, status: :created
    end

    def update
      @department.update!(department_params)

      render json: { department: serialize_one(@department, DepartmentSerializer) }
    end

    def destroy
      # Refused when tickets still point at it. `dependent: :nullify` would happily
      # orphan them, and "which department was this escalated to?" is not a
      # question an audit trail should lose — disabling keeps the history and
      # removes it from the picker.
      if @department.tickets.exists?
        raise Errors::Conflict.new(:department_in_use, name: @department.name)
      end

      @department.destroy!
      render json: { success: "OK" }
    end

    private

    def load_department
      @department = Department.find_by(id: params[:id])
      raise Errors::NotFound.new(:department_not_found) if @department.blank?
    end

    # Strong parameters, scoped to the fields an admin may set. `slug` is included
    # so it can be corrected after creation, but an empty value falls back to the
    # name — the model only auto-assigns when the column is blank.
    def department_params
      params.permit(
        :name,
        :slug,
        :description,
        :position,
        :enabled,
        :staff_group_name,
        :first_response_hours,
        :resolution_hours,
        :default_priority,
      ).to_h.symbolize_keys
    end
  end
end
