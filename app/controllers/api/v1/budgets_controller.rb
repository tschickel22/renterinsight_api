# frozen_string_literal: true

module Api
  module V1
    class BudgetsController < ApplicationController
      before_action :set_company_scope
      before_action :set_budget, only: %i[show update destroy lock unlock activate deactivate archive variance_report pl_overview]

      # GET /api/v1/budgets
      def index
        return unless authorize_action!('budgets', 'read')

        budgets = @company.budgets.includes(:location, :creator)

        if current_user.uses_rbac? && !current_user.effective_admin?
          location_ids = permission_service.accessible_location_ids
          budgets = budgets.where(
            'budgets.location_id IN (?) OR budgets.location_id IS NULL',
            location_ids.presence || [-1]
          )
        end

        budgets = budgets.for_current_location

        budgets = budgets.by_status(params[:status])                       if params[:status].present?
        budgets = budgets.by_fiscal_year(params[:fiscal_year])             if params[:fiscal_year].present?
        budgets = budgets.where(location_id: params[:location_id])         if params[:location_id].present?
        budgets = budgets.where(budget_type: params[:budget_type])         if params[:budget_type].present?
        budgets = budgets.where(consolidation_type: params[:consolidation_type]) if params[:consolidation_type].present?

        # Stats computed BEFORE the search filter so totals stay stable as the user types.
        stats = {
          counts_by_status: budgets.group(:status).count,
          counts_by_consolidation_type: budgets.group(:consolidation_type).count,
          total_budgeted_active: budgets.where(status: %w[active locked]).joins(:budget_lines).sum('budget_lines.annual_total').to_f.round(2)
        }

        if params[:search].present?
          budgets = budgets.where('budgets.name ILIKE ?', "%#{params[:search]}%")
        end

        total_count = budgets.count

        page     = (params[:page] || 1).to_i
        per_page = [(params[:per_page] || 50).to_i, 200].min

        budgets = budgets.order(fiscal_year: :desc, created_at: :desc)
                         .offset((page - 1) * per_page)
                         .limit(per_page)

        render json: {
          items: budgets.map { |b| budget_summary_json(b) },
          meta: {
            total:       total_count,
            page:        page,
            per_page:    per_page,
            total_pages: (total_count.to_f / per_page).ceil,
            stats:       stats
          }
        }
      end

      # GET /api/v1/budgets/:id
      def show
        return unless authorize_action!('budgets', 'read')

        lines = @budget.budget_lines.includes(:chart_of_account)
                       .joins(:chart_of_account)
                       .order('chart_of_accounts.account_number')

        render json: {
          budget:                  budget_detail_json(@budget),
          lines:                   lines.map { |l| line_json(l) },
          fiscal_year_start_month: BudgetService.fiscal_year_start_month(@company),
          data_coverage:           @budget.metadata['data_coverage']
        }
      end

      # POST /api/v1/budgets
      def create
        return unless authorize_action!('budgets', 'create')

        attrs = budget_params.to_h
        attrs['consolidation_type'] = 'standalone'
        attrs['created_by_id']      = current_user.id

        if Current.location_filtered? && (current_user.uses_rbac? && !current_user.effective_admin?)
          attrs['location_id'] = Current.location_id
        end

        budget = @company.budgets.build(attrs)

        if budget.save
          render json: { budget: budget_detail_json(budget) }, status: :created
        else
          render json: { error: budget.errors.full_messages.join(', ') }, status: :unprocessable_entity
        end
      end

      # PATCH /api/v1/budgets/:id
      def update
        return unless authorize_action!('budgets', 'update')

        if @budget.consolidated?
          return render json: { error: 'Consolidated budgets are read-only — edit the underlying location budgets instead.' }, status: :unprocessable_entity
        end

        if @budget.locked?
          return render json: { error: 'Budget is locked — unlock before editing.' }, status: :unprocessable_entity
        end

        if @budget.update(budget_params)
          lines = @budget.budget_lines.includes(:chart_of_account)
                         .joins(:chart_of_account)
                         .order('chart_of_accounts.account_number')
          render json: {
            budget: budget_detail_json(@budget),
            lines:  lines.map { |l| line_json(l) },
            fiscal_year_start_month: BudgetService.fiscal_year_start_month(@company)
          }
        else
          render json: { error: @budget.errors.full_messages.join(', ') }, status: :unprocessable_entity
        end
      end

      # DELETE /api/v1/budgets/:id
      def destroy
        return unless authorize_action!('budgets', 'delete')

        if @budget.consolidated?
          return render json: { error: 'Consolidated budgets cannot be deleted directly.' }, status: :unprocessable_entity
        end

        unless @budget.draft?
          return render json: { error: 'Only draft budgets can be deleted.' }, status: :unprocessable_entity
        end

        @budget.destroy!
        head :no_content
      end

      # POST /api/v1/budgets/:id/lock
      def lock
        return unless authorize_action!('budgets', 'update')
        return reject_consolidated_status_change if @budget.consolidated?

        @budget.update!(status: 'locked', locked_at: Time.current, locked_by_id: current_user.id)
        render json: { budget: budget_detail_json(@budget) }
      end

      # POST /api/v1/budgets/:id/unlock
      def unlock
        return unless authorize_action!('budgets', 'update')
        return reject_consolidated_status_change if @budget.consolidated?

        unless current_user.effective_admin?
          return render json: { error: 'Only admins can unlock budgets.' }, status: :forbidden
        end

        @budget.update!(status: 'draft', locked_at: nil, locked_by_id: nil)
        render json: { budget: budget_detail_json(@budget) }
      end

      # POST /api/v1/budgets/:id/activate
      def activate
        return unless authorize_action!('budgets', 'update')
        return reject_consolidated_status_change if @budget.consolidated?

        @budget.update!(status: 'active', approved_at: Time.current, approved_by_id: current_user.id)
        render json: { budget: budget_detail_json(@budget) }
      end

      # POST /api/v1/budgets/:id/deactivate
      # Moves active → draft so it can be edited or deleted. Admin only.
      def deactivate
        return unless authorize_action!('budgets', 'update')
        return reject_consolidated_status_change if @budget.consolidated?

        unless current_user.effective_admin?
          return render json: { error: 'Only admins can revert a budget to draft.' }, status: :forbidden
        end

        unless @budget.active?
          return render json: { error: "Budget must be active to revert to draft (current: #{@budget.status})." }, status: :unprocessable_entity
        end

        @budget.update!(status: 'draft', approved_at: nil, approved_by_id: nil)
        render json: { budget: budget_detail_json(@budget) }
      end

      # POST /api/v1/budgets/:id/archive
      def archive
        return unless authorize_action!('budgets', 'update')
        return reject_consolidated_status_change if @budget.consolidated?

        @budget.update!(status: 'archived')
        render json: { budget: budget_detail_json(@budget) }
      end

      # GET /api/v1/budgets/:id/pl-overview
      #
      # P&L-style monthly breakdown of the budget, grouped by account class:
      # Revenue, Cost of Goods Sold, Expense — with per-group subtotals and a
      # Net Income (Revenue - COGS - Expense) row. Returned in fiscal-month
      # order; the caller uses fiscal_year_start_month to render labels.
      def pl_overview
        return unless authorize_action!('budgets', 'read')

        lines = @budget.budget_lines.includes(:chart_of_account)
                       .joins(:chart_of_account)
                       .order('chart_of_accounts.account_number')

        zero_months = Array.new(12, 0.0)
        groups_data = {
          'revenue'            => { title: 'Revenue',            lines: [], subtotal_months: zero_months.dup },
          'cost_of_goods_sold' => { title: 'Cost of Goods Sold', lines: [], subtotal_months: zero_months.dup },
          'expense'            => { title: 'Expense',            lines: [], subtotal_months: zero_months.dup }
        }

        lines.each do |line|
          acct = line.chart_of_account
          group_key = pl_group_for(acct)
          next unless group_key

          months = (1..12).map { |m| line.public_send(:"month_#{m}").to_f.round(2) }
          annual_total = months.sum.round(2)

          groups_data[group_key][:lines] << {
            account_id:     acct.id,
            account_number: acct.account_number,
            account_name:   acct.name,
            account_type:   acct.account_type,
            sub_type:       acct.sub_type,
            months:         months,
            annual_total:   annual_total
          }

          months.each_with_index { |amt, i| groups_data[group_key][:subtotal_months][i] = (groups_data[group_key][:subtotal_months][i] + amt).round(2) }
        end

        groups = groups_data.map do |account_type, data|
          {
            account_type: account_type,
            title:        data[:title],
            lines:        data[:lines],
            subtotal: {
              months:       data[:subtotal_months],
              annual_total: data[:subtotal_months].sum.round(2)
            }
          }
        end

        revenue_months = groups_data['revenue'][:subtotal_months]
        cogs_months    = groups_data['cost_of_goods_sold'][:subtotal_months]
        expense_months = groups_data['expense'][:subtotal_months]

        net_income_months = (0..11).map do |i|
          (revenue_months[i] - cogs_months[i] - expense_months[i]).round(2)
        end

        render json: {
          budget: {
            id:                 @budget.id,
            name:               @budget.name,
            fiscal_year:        @budget.fiscal_year,
            status:             @budget.status,
            location_id:        @budget.location_id,
            location_name:      @budget.location_name,
            consolidation_type: @budget.consolidation_type
          },
          fiscal_year_start_month: BudgetService.fiscal_year_start_month(@company),
          groups: groups,
          net_income: {
            months:       net_income_months,
            annual_total: net_income_months.sum.round(2)
          }
        }
      end

      # GET /api/v1/budgets/:id/variance_report
      def variance_report
        return unless authorize_action!('budgets', 'read')

        period  = params[:period].presence || 'ytd'
        month   = params[:month].present?   ? params[:month].to_i   : nil
        quarter = params[:quarter].present? ? params[:quarter].to_i : nil

        report = BudgetService.calculate_variance(@budget, period: period, month: month, quarter: quarter)
        render json: report
      rescue ArgumentError => e
        render json: { error: e.message }, status: :bad_request
      end

      # POST /api/v1/budgets/copy-from-prior-year
      def copy_from_prior_year
        return unless authorize_action!('budgets', 'create')

        source_year     = params[:source_fiscal_year]
        target_year     = params[:target_fiscal_year].presence || (source_year.to_i + 1)
        growth_percent  = params[:growth_percent].presence || 0
        location_id     = resolve_location_id_from_params

        return render json: { error: 'source_fiscal_year is required' }, status: :bad_request if source_year.blank?

        result = BudgetService.create_from_prior_year(
          company:        @company,
          source_year:    source_year.to_i,
          target_year:    target_year.to_i,
          location_id:    location_id,
          growth_percent: growth_percent.to_f,
          name:           params[:name],
          created_by:     current_user
        )

        if result.success?
          render json: { budget: budget_detail_json(result.data),
                         lines:  result.data.budget_lines.includes(:chart_of_account).map { |l| line_json(l) } }, status: :created
        else
          render json: { error: result.message, suggest_wizard: result.message.include?('Wizard') },
                 status: :unprocessable_entity
        end
      end

      # POST /api/v1/budgets/wizard
      def wizard
        return unless authorize_action!('budgets', 'create')

        fiscal_year   = params[:fiscal_year]
        wizard_inputs = params[:wizard_inputs]
        location_id   = resolve_location_id_from_params

        return render json: { error: 'fiscal_year is required' },   status: :bad_request if fiscal_year.blank?
        return render json: { error: 'wizard_inputs is required' }, status: :bad_request if wizard_inputs.blank?

        inputs_hash = wizard_inputs.respond_to?(:to_unsafe_h) ? wizard_inputs.to_unsafe_h : wizard_inputs.to_h

        result = BudgetService.create_from_wizard(
          company:       @company,
          fiscal_year:   fiscal_year.to_i,
          location_id:   location_id,
          wizard_inputs: inputs_hash,
          name:          params[:name],
          created_by:    current_user
        )

        if result.success?
          render json: { budget: budget_detail_json(result.data),
                         lines:  result.data.budget_lines.includes(:chart_of_account).map { |l| line_json(l) } }, status: :created
        else
          render json: { error: result.message }, status: :unprocessable_entity
        end
      end

      # POST /api/v1/budgets/ai-suggest
      def ai_suggest
        return unless authorize_action!('budgets', 'update')

        budget_id = params[:budget_id]
        return render json: { error: 'budget_id is required' }, status: :bad_request if budget_id.blank?

        budget = @company.budgets.find_by(id: budget_id)
        return render json: { error: 'Budget not found' }, status: :not_found unless budget

        if budget.consolidated?
          return render json: { error: 'Consolidated budgets are read-only.' }, status: :unprocessable_entity
        end

        account_ids = Array(params[:chart_of_account_ids]).map(&:to_i).compact_blank
        result = BudgetService.ai_suggest_amounts(@company, budget, account_ids: account_ids)

        if result.success?
          render json: result.data
        else
          render json: { error: result.message }, status: :unprocessable_entity
        end
      end

      # GET /api/v1/budgets/data-coverage
      def data_coverage
        return unless authorize_action!('budgets', 'read')

        fiscal_year = params[:fiscal_year]
        return render json: { error: 'fiscal_year is required' }, status: :bad_request if fiscal_year.blank?

        location_id = resolve_location_id_from_params
        coverage = BudgetService.data_coverage(@company, fiscal_year.to_i, location_id: location_id)
        render json: coverage
      end

      # POST /api/v1/budgets/rebuild-consolidated
      def rebuild_consolidated
        return unless authorize_action!('budgets', 'update')

        unless current_user.effective_admin?
          return render json: { error: 'Only admins can rebuild the consolidated budget.' }, status: :forbidden
        end

        fiscal_year = params[:fiscal_year]
        return render json: { error: 'fiscal_year is required' }, status: :bad_request if fiscal_year.blank?

        consolidated = BudgetService.rebuild_consolidated(@company, fiscal_year.to_i)
        render json: { budget: budget_detail_json(consolidated),
                       lines:  consolidated.budget_lines.includes(:chart_of_account).map { |l| line_json(l) } }
      end

      # GET /api/v1/budgets/stats
      def stats
        return unless authorize_action!('budgets', 'read')

        scope = @company.budgets
        if current_user.uses_rbac? && !current_user.effective_admin?
          location_ids = permission_service.accessible_location_ids
          scope = scope.where(
            'budgets.location_id IN (?) OR budgets.location_id IS NULL',
            location_ids.presence || [-1]
          )
        end

        render json: {
          total:                        scope.count,
          counts_by_status:             scope.group(:status).count,
          counts_by_consolidation_type: scope.group(:consolidation_type).count,
          counts_by_fiscal_year:        scope.group(:fiscal_year).count,
          total_budgeted_active:        scope.where(status: 'active').joins(:budget_lines).sum('budget_lines.annual_total').to_f.round(2)
        }
      end

      private

      def set_budget
        @budget = @company.budgets.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Budget not found' }, status: :not_found
      end

      # Classifies a chart-of-account into the P&L overview group key.
      # Revenue and Expense are determined by account_type; COGS is an expense
      # account flagged via sub_type. Non-P&L accounts (asset/liability/equity)
      # return nil and are excluded from the report.
      def pl_group_for(acct)
        return nil unless acct
        return 'revenue' if acct.account_type == 'revenue'
        return 'cost_of_goods_sold' if acct.account_type == 'expense' && acct.sub_type == 'cost_of_goods_sold'
        return 'expense' if acct.account_type == 'expense'
        nil
      end

      def reject_consolidated_status_change
        render json: { error: 'Consolidated budgets are auto-managed and cannot transition status manually.' },
               status: :unprocessable_entity
      end

      def resolve_location_id_from_params
        if params[:location_id].present?
          params[:location_id].to_i
        elsif current_user.uses_rbac? && !current_user.effective_admin? && Current.location_filtered?
          Current.location_id
        end
      end

      def budget_params
        params.require(:budget).permit(
          :name, :description, :fiscal_year, :budget_type,
          :location_id, :notes,
          budget_lines_attributes: [:id, :chart_of_account_id, :notes, :_destroy,
                                    :month_1, :month_2, :month_3, :month_4,
                                    :month_5, :month_6, :month_7, :month_8,
                                    :month_9, :month_10, :month_11, :month_12]
        )
      end

      def budget_summary_json(b)
        {
          id:                 b.id,
          name:               b.name,
          fiscal_year:        b.fiscal_year,
          status:             b.status,
          budget_type:        b.budget_type,
          consolidation_type: b.consolidation_type,
          location_id:        b.location_id,
          location_name:      b.location_name,
          total_amount:       b.total_amount.to_f.round(2),
          line_count:         b.budget_lines.size,
          created_by:         b.creator&.respond_to?(:name) ? b.creator.name : b.creator&.email,
          created_at:         b.created_at&.iso8601,
          updated_at:         b.updated_at&.iso8601,
          locked_at:          b.locked_at&.iso8601
        }
      end

      def budget_detail_json(b)
        budget_summary_json(b).merge(
          description:        b.description,
          notes:              b.notes,
          approved_at:        b.approved_at&.iso8601,
          approved_by:        b.approver&.respond_to?(:name) ? b.approver.name : b.approver&.email,
          locked_by:          b.locker&.respond_to?(:name)  ? b.locker.name  : b.locker&.email,
          metadata:           b.metadata,
          editable:           b.editable?
        )
      end

      def line_json(line)
        acct = line.chart_of_account
        {
          id:                  line.id,
          chart_of_account_id: line.chart_of_account_id,
          chart_of_account: acct ? {
            id:             acct.id,
            account_number: acct.account_number,
            name:           acct.name,
            account_type:   acct.account_type,
            sub_type:       acct.sub_type,
            normal_balance: acct.normal_balance
          } : nil,
          month1:  line.month_1.to_f,  month2:  line.month_2.to_f,
          month3:  line.month_3.to_f,  month4:  line.month_4.to_f,
          month5:  line.month_5.to_f,  month6:  line.month_6.to_f,
          month7:  line.month_7.to_f,  month8:  line.month_8.to_f,
          month9:  line.month_9.to_f,  month10: line.month_10.to_f,
          month11: line.month_11.to_f, month12: line.month_12.to_f,
          annual_total: line.annual_total.to_f,
          notes:        line.notes
        }
      end
    end
  end
end
