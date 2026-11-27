# frozen_string_literal: true

module Api
  module V1
    class ReportsController < ApplicationController
      before_action :set_company_scope
      before_action :set_report, only: %i[update destroy]
      before_action :set_visible_report, only: %i[show]

      # GET /api/v1/reports
      def index
        # Visibility rules:
        #   private  → only the creator (or users in shared_user_ids)
        #   location → everyone at the same location
        #   company  → everyone in the company
        #   platform → everyone (cross-company; admin-only to set)
        reports = visible_reports.includes(:user).order(updated_at: :desc)

        render json: reports.map { |r|
          creator = r.user
          shared_users = User.where(id: r.shared_user_ids_array).map { |u|
            { id: u.id, name: "#{u.first_name} #{u.last_name}".strip.presence || u.email, email: u.email }
          }
          {
            id:           r.id,
            name:         r.name,
            module_key:   r.module_key,
            is_favorite:  r.is_favorite,
            visibility:   r.visibility || 'private',
            created_by:   creator ? "#{creator.first_name} #{creator.last_name}".strip.presence || creator.email : 'System',
            is_owner:     r.user_id == current_user&.id || current_user&.effective_admin?,
            shared_users: shared_users,
            updated_at:   r.updated_at
          }
        }
      end

      # GET /api/v1/reports/:id
      def show
        creator = @report.user
        shared_users = User.where(id: @report.shared_user_ids_array).map { |u|
          { id: u.id, name: "#{u.first_name} #{u.last_name}".strip.presence || u.email, email: u.email }
        }
        render json: {
          id:           @report.id,
          name:         @report.name,
          description:  @report.description,
          module_key:   @report.module_key,
          config:       @report.config,
          status:       @report.status,
          is_favorite:  @report.is_favorite,
          visibility:   @report.visibility || 'private',
          created_by:   creator ? "#{creator.first_name} #{creator.last_name}".strip.presence || creator.email : 'System',
          is_owner:     @report.user_id == current_user&.id || current_user&.effective_admin?,
          shared_users: shared_users,
          created_at:   @report.created_at,
          updated_at:   @report.updated_at
        }
      end

      # POST /api/v1/reports
      def create
        report = @company.reports.new(report_params)
        report.user_id = current_user&.id
        report.location_id = Current.location_id if defined?(Current) && Current.respond_to?(:location_id)
        if report.save
          render json: report, status: :created
        else
          render json: { errors: report.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # PATCH/PUT /api/v1/reports/:id
      def update
        unless @report.user_id == current_user&.id || current_user&.effective_admin?
          return render json: { error: 'Not authorized to edit this report' }, status: :forbidden
        end
        if @report.update(report_params)
          render json: @report
        else
          render json: { errors: @report.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # DELETE /api/v1/reports/:id
      def destroy
        unless @report.user_id == current_user&.id || current_user&.effective_admin?
          return render json: { error: 'Not authorized to delete this report' }, status: :forbidden
        end
        @report.update(is_deleted: true)
        head :no_content
      end

      # POST /api/v1/reports/run
      def run
        return unless authorize_report_module!(params[:module_key])

        # Convert ActionController::Parameters to plain hash so ReportEngine
        # can safely call .with_indifferent_access on nested objects.
        raw_filters = params[:filters]
        safe_filters = raw_filters.respond_to?(:to_unsafe_h) ? raw_filters.to_unsafe_h : (raw_filters || {})

        result = ReportEngine.run(
          module:      params[:module_key],
          fields:      params[:fields],
          filters:     safe_filters,
          sort_by:     params[:sort_by],
          sort_order:  params[:sort_order],
          page:        params[:page] || 1,
          per_page:    params[:per_page] || 50,
          company_id:  @company.id,
          location_id: (defined?(Current) && Current.respond_to?(:location_id) ? Current.location_id : nil),
          user:        current_user,
          **grouping(params)
        )
        render json: result
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # POST /api/v1/reports/:id/share
      def share
        @report = @company.reports.active.find(params[:id])
        unless @report.user_id == current_user&.id || current_user&.effective_admin?
          return render json: { error: 'Not authorized' }, status: :forbidden
        end

        share_type = params[:share_type] # 'user' | 'location' | 'company' | 'platform'

        case share_type
        when 'user'
          email = params[:email]&.strip&.downcase
          target_user = @company.users.find_by("LOWER(email) = ?", email)
          return render json: { error: "No user found with email #{email}" }, status: :not_found unless target_user
          return render json: { error: 'Cannot share with yourself' }, status: :unprocessable_entity if target_user.id == current_user&.id

          current_ids = @report.shared_user_ids_array
          unless current_ids.include?(target_user.id)
            @report.update!(shared_user_ids: current_ids + [target_user.id])
          end

          render json: {
            message: "Shared with #{target_user.email}",
            shared_user: {
              id:    target_user.id,
              name:  "#{target_user.first_name} #{target_user.last_name}".strip.presence || target_user.email,
              email: target_user.email
            }
          }

        when 'location', 'company', 'platform'
          if share_type == 'platform' && !current_user&.effective_admin?
            return render json: { error: 'Only admins can share at platform level' }, status: :forbidden
          end

          @report.update!(visibility: share_type)
          render json: { message: "Visibility updated to #{share_type}", visibility: share_type }
        else
          render json: { error: 'Invalid share_type' }, status: :unprocessable_entity
        end
      end

      # DELETE /api/v1/reports/:id/unshare
      def unshare
        @report = @company.reports.active.find(params[:id])
        unless @report.user_id == current_user&.id || current_user&.effective_admin?
          return render json: { error: 'Not authorized' }, status: :forbidden
        end

        user_id = params[:user_id]&.to_i
        if user_id.present? && user_id > 0
          updated_ids = @report.shared_user_ids_array - [user_id]
          @report.update!(shared_user_ids: updated_ids)
          render json: { message: 'User removed from shared access' }
        else
          @report.update!(visibility: 'private', shared_user_ids: [])
          render json: { message: 'Report set to private' }
        end
      end

      # GET /api/v1/reports/:id/export
      # Server-side CSV export: up to ReportEngine::MAX_PER_PAGE rows, with
      # X-Export-Total and X-Export-Rows saying when the file was cut.
      def export
        @report = visible_reports_for_open.find(params[:id])
        cfg = @report.config || {}
        return unless authorize_report_module!(cfg['module_key'] || @report.module_key)

        export = ReportExport.call(
          company: @company, user: current_user, location_id: Current.location_id, name: @report.name, ip: request.remote_ip,
          query: { module: cfg['module_key'] || @report.module_key, fields: cfg['fields'], filters: cfg['filters'] || {},
                   sort_by: cfg['sort_by'], sort_order: cfg['sort_order'], **grouping(cfg) }
        )
        send_export(export)
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Not found' }, status: :not_found
      rescue ArgumentError => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # GET /api/v1/reports/modules
      # Only the modules this person can read in the app.
      def modules
        render json: ReportEngine.modules_list.select { |m| can_read_report_module?(m[:key]) }
      end

      # GET /api/v1/reports/fields
      def fields
        return unless authorize_report_module!(params[:module_key])

        render json: ReportEngine.field_definitions(params[:module_key], @company.id)
      end

      private

      # A grouped report's settings (ReportEngine::Grouped), from a request or
      # a saved report's config. The engine checks every field.
      def grouping(source)
        source = source.respond_to?(:to_unsafe_h) ? source.to_unsafe_h : source.to_h
        source = source.with_indifferent_access
        return {} if source[:group_by].blank?

        aggregates = Array(source[:aggregates]).map { |a| a.respond_to?(:to_unsafe_h) ? a.to_unsafe_h : a.to_h }
        { group_by: source[:group_by].to_s, group_period: source[:group_period].presence, aggregates: aggregates.presence }.compact
      end

      def send_export(export)
        response.headers['X-Export-Total'] = export.total.to_s
        response.headers['X-Export-Rows'] = export.rows.to_s
        send_data export.csv, filename: export.filename, type: 'text/csv', disposition: 'attachment'
      end

      # A report reads the same records as the module's own list, so it needs
      # the same read permission. Reports used to need none, which let anyone
      # in the company report on journal entries, bills or bank transactions.
      def authorize_report_module!(module_key)
        resource = ReportEngine.read_resource_for(module_key)
        unless resource
          render json: { error: "Unknown report module: #{module_key}" }, status: :unprocessable_entity
          return false
        end

        authorize_action!(resource, 'read')
      end

      def can_read_report_module?(module_key)
        resource = ReportEngine.read_resource_for(module_key)
        resource.present? && can?(resource, 'read')
      end

      def set_report
        @report = @company.reports.active.find(params[:id])
      end

      # Reports this person may see, the list's rule: company and platform
      # ones, their location's, their own, and ones shared with them.
      def visible_reports
        @company.reports.active.where(
          "visibility = 'company' " \
          "OR visibility = 'platform' " \
          "OR (visibility = 'location' AND location_id = ?) " \
          "OR user_id = ? " \
          "OR shared_user_ids @> ?::jsonb",
          Current.location_id,
          current_user&.id,
          [current_user&.id].to_json
        )
      end

      # Opening one by id follows the same rule (anyone in the company could
      # open a private report by its id, 2026-11-27); admins, who can edit
      # and delete any report, can open any.
      def visible_reports_for_open
        current_user&.effective_admin? ? @company.reports.active : visible_reports
      end

      def set_visible_report
        @report = visible_reports_for_open.find_by(id: params[:id])
        render json: { error: 'Report not found' }, status: :not_found unless @report
      end

      def report_params
        permitted = params.require(:report).permit(:name, :description, :module_key, :is_favorite, :visibility, config: {})
        # Allow arbitrary nested config JSON
        permitted[:config] = params[:report][:config].to_unsafe_h if params[:report][:config].respond_to?(:to_unsafe_h)
        permitted
      end
    end
  end
end
