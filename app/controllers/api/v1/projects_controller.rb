# frozen_string_literal: true

module Api
  module V1
    class ProjectsController < ApplicationController
      before_action :set_company_scope
      before_action :set_project, only: %i[show update destroy advance_phase undo_advance skip_phase set_phase_status toggle_task assign_phase_task_contractor unassign_phase_task_contractor assign_phase_task_user unassign_phase_task_user export_pdf]

      # GET /api/v1/projects
      def index
        return unless authorize_action!('deals', 'read')

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

        # Location selector filter — skip when all_locations=true (e.g. deal project lookup)
        unless params[:all_locations] == 'true'
          projects = projects.for_current_location
        end

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
                     budget_amount actual_cost labor_cost materials_cost subcontractor_cost other_cost land_parcel_id
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
        return unless authorize_action!('deals', 'read')

        render json: {
          project: @project.as_json(
            only: %i[id name project_number description status progress_percent phase_count completed_phase_count
                     customer_name customer_email customer_phone home_make home_model home_serial_number
                     delivery_street delivery_city delivery_state delivery_zip
                     started_at estimated_completion_date actual_completion_date
                     owner_id deal_id vehicle_id location_id current_phase_id project_template_id
                     budget_amount actual_cost labor_cost materials_cost subcontractor_cost other_cost land_parcel_id
                     client_visible client_access_token custom_field_values created_at updated_at],
            methods: [:current_phase_name, :progress_display, :home_display_name, :delivery_address_display]
          ),
          phases: @project.project_phases.ordered.includes(project_phase_tasks: [:assigned_to, { contractor_assignments: :contractor }]).as_json(
            only: %i[id name description position status is_required
                     started_at completed_at estimated_start_date estimated_completion_date estimated_days
                     estimated_budget actual_cost
                     visible_to_client notify_client_on_start notify_client_on_complete
                     notes client_notes icon color completed_by_id created_at updated_at],
            methods: [:status_display, :overdue?, :duration_days, :task_progress_percent, :tasks_summary,
                      :computed_estimated_days, :computed_start_date, :computed_completion_date],
            include: {
              project_phase_tasks: {
                only: %i[id name position status is_required completed_at completed_by_id
                         assigned_to_id visible_to_client client_actionable client_acknowledged_at client_acknowledged_by
                         estimated_days estimated_start_date estimated_completion_date],
                methods: [:work_log_count],
                include: {
                  assigned_to: {
                    only: %i[id first_name last_name email]
                  },
                  contractor_assignments: {
                    only: %i[id status assigned_at],
                    include: {
                      contractor: {
                        only: %i[id name contact_name trade_type phone email]
                      }
                    }
                  }
                }
              }
            }
          )
        }
      end

      # GET /api/v1/projects/:id/export_pdf
      def export_pdf
        return unless authorize_action!('deals', 'read')

        sections = if params[:sections].present?
          params[:sections].split(',').map(&:strip)
        else
          nil
        end

        pdf_content = ProjectPdfGenerator.new(@project, sections: sections, company: @company).generate

        send_data pdf_content,
          filename: "Project-#{@project.project_number || @project.id}.pdf",
          type: 'application/pdf',
          disposition: params[:inline] == 'true' ? 'inline' : 'attachment'
      end

      # POST /api/v1/projects
      def create
        return unless authorize_action!('deals', 'create')

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
        return unless authorize_action!('deals', 'update')

        # Merge custom_field_values (Section 24 pattern)
        if params[:project][:custom_field_values].present?
          existing = @project.custom_field_values || {}
          merged = existing.merge(params[:project][:custom_field_values].to_unsafe_h)
          params[:project][:custom_field_values] = merged
        end

        if @project.update(project_params)
          render json: @project.as_json(
            only: %i[id name project_number description status progress_percent customer_name
                     estimated_completion_date owner_id client_visible
                     budget_amount actual_cost labor_cost materials_cost subcontractor_cost other_cost land_parcel_id
                     updated_at],
            methods: [:current_phase_name]
          )
        else
          render json: { errors: @project.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # DELETE /api/v1/projects/:id
      def destroy
        return unless authorize_action!('deals', 'delete')

        @project.update!(is_deleted: true)
        render json: { message: 'Project deleted' }
      end

      # POST /api/v1/projects/:id/advance_phase
      def advance_phase
        return unless authorize_action!('deals', 'update')

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

      # POST /api/v1/projects/:id/set_phase_status
      def set_phase_status
        return unless authorize_action!('deals', 'update')

        phase = @project.project_phases.find_by(id: params[:phase_id])
        return render(json: { error: 'Phase not found' }, status: :not_found) unless phase

        new_status = params[:status]
        return render(json: { error: 'Status is required' }, status: :bad_request) if new_status.blank?

        result = @project.set_phase_status!(phase, new_status, changed_by: current_user)

        if result[:error]
          render json: { error: result[:error] }, status: :unprocessable_entity
        else
          render json: {
            message: "Phase '#{phase.name}' set to #{new_status.humanize}",
            phase: result[:phase].as_json(
              only: %i[id name position status started_at completed_at completed_by_id]
            ),
            project: @project.reload.as_json(
              only: %i[id status progress_percent completed_phase_count phase_count current_phase_id actual_completion_date],
              methods: [:current_phase_name]
            )
          }
        end
      end

      # POST /api/v1/projects/:id/undo_advance
      def undo_advance
        return unless authorize_action!('deals', 'update')

        result = @project.undo_last_advance!(undone_by: current_user)

        if result[:error]
          render json: { error: result[:error] }, status: :unprocessable_entity
        else
          render json: {
            message: "Phase '#{result[:restored_phase].name}' restored to in progress",
            restored_phase: result[:restored_phase].as_json(only: %i[id name status started_at]),
            reverted_phase: result[:reverted_phase]&.as_json(only: %i[id name status]),
            project: @project.reload.as_json(
              only: %i[id status progress_percent completed_phase_count current_phase_id actual_completion_date],
              methods: [:current_phase_name]
            )
          }
        end
      end

      # POST /api/v1/projects/:id/skip_phase
      def skip_phase
        return unless authorize_action!('deals', 'update')

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

      # POST /api/v1/projects/:id/toggle_task
      # Body: { phase_id: N, task_id: N }
      def toggle_task
        return unless authorize_action!('deals', 'update')

        phase = @project.project_phases.find_by(id: params[:phase_id])
        return render(json: { error: 'Phase not found' }, status: :not_found) unless phase

        task = phase.project_phase_tasks.find_by(id: params[:task_id])
        return render(json: { error: 'Task not found' }, status: :not_found) unless task

        if task.status == 'completed'
          task.reopen!
        else
          task.complete!(by: current_user)
          # Auto-advance phase to in_progress when first task is checked
          if phase.status == 'not_started'
            phase.update!(status: 'in_progress', started_at: phase.started_at || Time.current)
            @project.recalc_current_phase!
            @project.update_progress_cache!
            @project.save!
          end
        end

        render json: {
          task: task.as_json(only: %i[id name status completed_at]),
          phase: phase.reload.as_json(
            only: %i[id status started_at],
            methods: %i[task_progress_percent tasks_summary]
          ),
          project: @project.reload.as_json(
            only: %i[id progress_percent completed_phase_count current_phase_id]
          )
        }
      end

      # POST /api/v1/projects/:id/assign_phase_task_contractor
      # Body: { phase_id:, task_id:, contractor_id:, notes: }
      def assign_phase_task_contractor
        return unless authorize_action!('contractors', 'create')

        phase = @project.project_phases.find_by(id: params[:phase_id])
        return render(json: { error: 'Phase not found' }, status: :not_found) unless phase

        task = phase.project_phase_tasks.find_by(id: params[:task_id])
        return render(json: { error: 'Task not found' }, status: :not_found) unless task

        contractor = @company.contractors.not_deleted.find(params[:contractor_id])

        # Check if already assigned
        existing = task.contractor_assignments.find_by(contractor_id: contractor.id)
        if existing
          return render(json: { error: 'Contractor already assigned to this task' }, status: :unprocessable_entity)
        end

        assignment = task.contractor_assignments.build(
          contractor: contractor,
          company: @company,
          assigned_by: current_user,
          status: 'assigned',
          assigned_at: Time.current,
          notes: params[:notes]
        )

        if assignment.save
          render json: {
            message: 'Contractor assigned',
            assignment: {
              id: assignment.id,
              contractorId: contractor.id,
              contractorName: contractor.name,
              contactName: contractor.contact_name,
              tradeType: contractor.trade_type,
              status: assignment.status,
              assignedAt: assignment.assigned_at
            }
          }, status: :created
        else
          render json: { errors: assignment.errors.full_messages }, status: :unprocessable_entity
        end
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Contractor not found' }, status: :not_found
      end

      # DELETE /api/v1/projects/:id/unassign_phase_task_contractor
      # Body: { phase_id:, task_id:, contractor_id: }
      def unassign_phase_task_contractor
        return unless authorize_action!('contractors', 'delete')

        phase = @project.project_phases.find_by(id: params[:phase_id])
        return render(json: { error: 'Phase not found' }, status: :not_found) unless phase

        task = phase.project_phase_tasks.find_by(id: params[:task_id])
        return render(json: { error: 'Task not found' }, status: :not_found) unless task

        assignment = task.contractor_assignments.find_by!(contractor_id: params[:contractor_id])
        assignment.destroy
        head :no_content
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Assignment not found' }, status: :not_found
      end

      # POST /api/v1/projects/:id/assign_phase_task_user
      # Body: { phase_id:, task_id:, user_id: }
      def assign_phase_task_user
        return unless authorize_action!('deals', 'update')

        phase = @project.project_phases.find_by(id: params[:phase_id])
        return render(json: { error: 'Phase not found' }, status: :not_found) unless phase

        task = phase.project_phase_tasks.find_by(id: params[:task_id])
        return render(json: { error: 'Task not found' }, status: :not_found) unless task

        user = @company.users.find_by(id: params[:user_id])
        return render(json: { error: 'User not found' }, status: :not_found) unless user

        task.update!(assigned_to: user)

        render json: {
          message: 'User assigned',
          task: {
            id: task.id,
            name: task.name,
            assignedToId: user.id,
            assignedTo: {
              id: user.id,
              firstName: user.first_name,
              lastName: user.last_name,
              email: user.email
            }
          }
        }
      end

      # DELETE /api/v1/projects/:id/unassign_phase_task_user
      # Body: { phase_id:, task_id: }
      def unassign_phase_task_user
        return unless authorize_action!('deals', 'update')

        phase = @project.project_phases.find_by(id: params[:phase_id])
        return render(json: { error: 'Phase not found' }, status: :not_found) unless phase

        task = phase.project_phase_tasks.find_by(id: params[:task_id])
        return render(json: { error: 'Task not found' }, status: :not_found) unless task

        task.update!(assigned_to: nil)
        head :no_content
      end

      # GET /api/v1/projects/grid
      # Template-aware grid for the Project Summary page
      def grid
        return unless authorize_action!('deals', 'read')

        template_id = params[:template_id]
        return render(json: { error: 'template_id is required' }, status: :bad_request) if template_id.blank?

        template = @company.project_templates.active.find_by(id: template_id)
        return render(json: { error: 'Template not found' }, status: :not_found) unless template

        template_phases = template.project_template_phases.order(:position)

        projects = @company.projects.not_deleted
                           .where(project_template_id: template_id)
                           .includes(:project_phases, :location, deal: [:account, :contact])

        unless params[:include_completed] == 'true'
          projects = projects.where.not(status: 'completed')
        end

        projects = projects.where(location_id: params[:location_id]) if params[:location_id].present?

        if current_user.uses_rbac? && !current_user.effective_admin?
          location_ids = permission_service.accessible_location_ids
          projects = location_ids.any? ? projects.where(location_id: location_ids) : projects.none
        end

        page        = (params[:page] || 1).to_i
        per_page    = [(params[:per_page] || 100).to_i, 500].min
        total_count = projects.count
        projects    = projects.order(created_at: :desc).offset((page - 1) * per_page).limit(per_page)

        project_rows = projects.map do |project|
          phase_map = {}
          project.project_phases.includes(:project_phase_tasks).each do |ph|
            task_pct = ph.task_progress_percent  # nil if no tasks, 0-100 if tasks exist
            pct = if ph.status == 'completed' || ph.status == 'skipped'
                    100
                  elsif task_pct.present?
                    # Use task completion % when tasks exist
                    task_pct
                  elsif ph.status == 'in_progress'
                    if ph.started_at && ph.estimated_days.to_i > 0
                      elapsed = ((Time.current - ph.started_at) / 1.day).round
                      [(elapsed.to_f / ph.estimated_days * 100).round, 99].min
                    else
                      50
                    end
                  else
                    0
                  end
            phase_map[ph.position] = { status: ph.status, progress_percent: pct }
          end

          deal = project.deal
          {
            id:                    project.id,
            project_number:        project.project_number,
            status:                project.status,
            progress_percent:      project.progress_percent,
            completed_phase_count: project.completed_phase_count,
            phase_count:           project.phase_count,
            current_phase_name:    project.current_phase_name,
            deal: deal ? { id: deal.id, name: deal.name, deal_number: deal.deal_number, value: deal.calculated_value } : nil,
            account: deal&.account ? { id: deal.account.id, name: deal.account.name } : nil,
            contact: deal&.contact ? { id: deal.contact.id, full_name: [deal.contact.first_name, deal.contact.last_name].compact.join(' ') } : nil,
            location: project.location ? { id: project.location.id, name: project.location.name } : nil,
            phases: template_phases.map do |tp|
              pd = phase_map[tp.position] || {}
              { template_phase_id: tp.id, position: tp.position, status: pd[:status] || 'not_started', progress_percent: pd[:progress_percent] || 0 }
            end
          }
        end

        render json: {
          template: { id: template.id, name: template.name, phases: template_phases.as_json(only: %i[id name position color icon]) },
          projects: project_rows,
          meta: { total: total_count, page: page, per_page: per_page, total_pages: (total_count.to_f / per_page).ceil }
        }
      end

      # GET /api/v1/projects/summary
      def summary
        return unless authorize_action!('deals', 'read')

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

        active_projects = projects.where(status: 'active')

        render json: {
          total: projects.count,
          active: active_projects.count,
          completed: projects.where(status: 'completed').count,
          on_hold: projects.where(status: 'on_hold').count,
          cancelled: projects.where(status: 'cancelled').count,
          avg_progress: active_projects.average(:progress_percent)&.round(1) || 0,
          overdue: active_projects.where("estimated_completion_date < ?", Date.current).count,
          recent: projects.order(created_at: :desc).limit(5).as_json(
            only: %i[id name project_number status progress_percent customer_name current_phase_id created_at],
            methods: [:current_phase_name, :home_display_name]
          )
        }
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
          :budget_amount, :land_parcel_id,
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
