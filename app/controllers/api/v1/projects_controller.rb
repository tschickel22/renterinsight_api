# frozen_string_literal: true

module Api
  module V1
    class ProjectsController < ApplicationController
      before_action :set_company_scope
      before_action :set_project, only: %i[show update destroy advance_phase skip_phase]

      # GET /api/v1/projects
      def index
        return unless authorize_action!('projects', 'read')

        projects = @company.projects.not_deleted

        # RBAC location filtering
        if current_user.uses_rbac?
          unless current_user.effective_admin?
            location_ids = permission_service.accessible_location_ids
            projects = location_ids.any? ?
              projects.where("location_id IN (?) OR location_id IS NULL", location_ids) :
              projects
          end
        end

        # Location selector filter
        projects = projects.for_current_location

        # Stats BEFORE search (for tiles)
        all_count = projects.count
        status_counts = {
          active: projects.where(status: 'active').count,
          completed: projects.where(status: 'completed').count,
          on_hold: projects.where(status: 'on_hold').count,
          cancelled: projects.where(status: 'cancelled').count
        }

        # Filters
        projects = projects.by_status(params[:status]) if params[:status].present?
        projects = projects.by_owner(params[:owner_id]) if params[:owner_id].present?
        projects = projects.by_deal(params[:deal_id]) if params[:deal_id].present?

        # Search
        if params[:search].present?
          search_term = "%#{params[:search]}%"
          projects = projects.where(
            "name ILIKE ? OR project_number ILIKE ? OR customer_name ILIKE ? OR home_make ILIKE ? OR home_model ILIKE ?",
            search_term, search_term, search_term, search_term, search_term
          )
        end

        # Sorting
        sort_by = params[:sort_by] || 'created_at'
        sort_order = params[:sort_order]&.downcase == 'asc' ? :asc : :desc
        allowed_sorts = %w[created_at updated_at name project_number status progress_percent customer_name]
        sort_by = 'created_at' unless allowed_sorts.include?(sort_by)
        projects = projects.order(sort_by => sort_order)

        # Count after filters (for pagination)
        filtered_count = projects.count

        # Paginate
        page = (params[:page] || 1).to_i
        per_page = [(params[:per_page] || 50).to_i, 200].min
        projects = projects.offset((page - 1) * per_page).limit(per_page)

        render json: {
          items: projects.as_json(
            only: %i[id name project_number status progress_percent phase_count completed_phase_count
                     customer_name customer_email customer_phone home_make home_model home_serial_number
                     delivery_street delivery_city delivery_state delivery_zip
                     started_at estimated_completion_date actual_completion_date
                     owner_id deal_id vehicle_id location_id current_phase_id
                     client_visible created_at updated_at],
            methods: [:current_phase_name, :progress_display, :home_display_name, :delivery_address_display]
          ),
          meta: {
            total: filtered_count,
            page: page,
            per_page: per_page,
            total_pages: (filtered_count.to_f / per_page).ceil,
            stats: status_counts.merge(total: all_count)
          }
        }
      end

      # GET /api/v1/projects/:id
      def show
        return unless authorize_action!('projects', 'read')

        render json: {
          project: @project.as_json(
            only: %i[id name project_number description status progress_percent phase_count completed_phase_count
                     customer_name customer_email customer_phone home_make home_model home_serial_number
                     delivery_street delivery_city delivery_state delivery_zip
                     started_at estimated_completion_date actual_completion_date
                     owner_id deal_id vehicle_id location_id current_phase_id project_template_id
                     client_visible client_access_token custom_field_values created_at updated_at],
            methods: [:current_phase_name, :progress_display, :home_display_name, :delivery_address_display]
          ),
          phases: @project.project_phases.ordered.as_json(
            only: %i[id name description position status is_required
                     started_at completed_at estimated_start_date estimated_completion_date estimated_days
                     visible_to_client notify_client_on_start notify_client_on_complete
                     notes client_notes icon color completed_by_id created_at updated_at],
            methods: [:status_display, :overdue?, :duration_days]
          )
        }
      end

      # POST /api/v1/projects
      def create
        return unless authorize_action!('projects', 'create')

        if params[:template_id].present? && params[:deal_id].present?
          # Create from template + deal
          create_from_template_and_deal
        elsif params[:template_id].present?
          # Create from template (standalone)
          create_from_template
        else
          # Manual creation
          create_manual
        end
      end

      # PATCH /api/v1/projects/:id
      def update
        return unless authorize_action!('projects', 'update')

        # Merge custom_field_values (Section 24 pattern)
        if params[:project][:custom_field_values].present?
          existing = @project.custom_field_values || {}
          merged = existing.merge(params[:project][:custom_field_values].to_unsafe_h)
          params[:project][:custom_field_values] = merged
        end

        if @project.update(project_params)
          render json: @project.as_json(
            only: %i[id name project_number description status progress_percent customer_name
                     estimated_completion_date owner_id client_visible updated_at],
            methods: [:current_phase_name]
          )
        else
          render json: { errors: @project.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # DELETE /api/v1/projects/:id
      def destroy
        return unless authorize_action!('projects', 'delete')

        @project.update!(is_deleted: true)
        render json: { message: 'Project deleted' }
      end

      # POST /api/v1/projects/:id/advance_phase
      def advance_phase
        return unless authorize_action!('projects', 'update')

        result = @project.advance_phase!(completed_by: current_user)

        if result[:error]
          render json: { error: result[:error] }, status: :unprocessable_entity
        else
          render json: {
            message: "Phase '#{result[:completed_phase].name}' completed",
            completed_phase: result[:completed_phase].as_json(only: %i[id name status completed_at]),
            next_phase: result[:next_phase]&.as_json(only: %i[id name status started_at]),
            project: @project.reload.as_json(
              only: %i[id status progress_percent completed_phase_count current_phase_id actual_completion_date],
              methods: [:current_phase_name]
            )
          }
        end
      end

      # POST /api/v1/projects/:id/skip_phase
      def skip_phase
        return unless authorize_action!('projects', 'update')

        phase = @project.project_phases.find_by(id: params[:phase_id])
        return render(json: { error: 'Phase not found' }, status: :not_found) unless phase

        result = @project.skip_phase!(phase, skipped_by: current_user)

        if result[:error]
          render json: { error: result[:error] }, status: :unprocessable_entity
        else
          render json: {
            message: "Phase '#{result[:skipped_phase].name}' skipped",
            project: @project.reload.as_json(
              only: %i[id status progress_percent completed_phase_count current_phase_id],
              methods: [:current_phase_name]
            )
          }
        end
      end

      private

      def set_project
        @project = @company.projects.not_deleted.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Project not found' }, status: :not_found
      end

      def project_params
        params.require(:project).permit(
          :name, :description, :status, :owner_id, :location_id,
          :customer_name, :customer_email, :customer_phone,
          :home_make, :home_model, :home_serial_number, :vehicle_id,
          :delivery_street, :delivery_city, :delivery_state, :delivery_zip,
          :estimated_completion_date, :client_visible,
          custom_field_values: {}
          # NEVER permit: :company_id (Section 16)
        )
      end

      def create_from_template_and_deal
        template = @company.project_templates.active.find_by(id: params[:template_id])
        return render(json: { error: 'Template not found' }, status: :not_found) unless template

        deal = @company.deals.find_by(id: params[:deal_id])
        return render(json: { error: 'Deal not found' }, status: :not_found) unless deal

        project = template.create_project!(
          company: @company,
          deal: deal,
          name: params[:name],
          owner: current_user,
          created_by: current_user
        )

        # Auto-start the project
        project.start!

        render json: {
          project: project.as_json(
            only: %i[id name project_number status progress_percent customer_name current_phase_id],
            methods: [:current_phase_name]
          ),
          phases: project.project_phases.ordered.as_json(
            only: %i[id name position status visible_to_client icon color]
          )
        }, status: :created

      rescue ActiveRecord::RecordInvalid => e
        render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
      end

      def create_from_template
        template = @company.project_templates.active.find_by(id: params[:template_id])
        return render(json: { error: 'Template not found' }, status: :not_found) unless template

        project = template.create_project!(
          company: @company,
          name: params[:name],
          owner: current_user,
          created_by: current_user
        )

        project.start!

        render json: {
          project: project.as_json(
            only: %i[id name project_number status progress_percent current_phase_id],
            methods: [:current_phase_name]
          )
        }, status: :created

      rescue ActiveRecord::RecordInvalid => e
        render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
      end

      def create_manual
        project = @company.projects.build(project_params)
        project.owner_id ||= current_user.id
        project.created_by_id = current_user.id
        project.location_id ||= Current.location_id if Current.location_id.present?

        if project.save
          render json: project.as_json(
            only: %i[id name project_number status created_at]
          ), status: :created
        else
          render json: { errors: project.errors.full_messages }, status: :unprocessable_entity
        end
      end
    end
  end
end
