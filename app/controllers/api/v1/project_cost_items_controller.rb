# frozen_string_literal: true

module Api
  module V1
    class ProjectCostItemsController < ApplicationController
      before_action :set_company_scope
      before_action :set_project
      before_action :set_cost_item, only: %i[show update destroy approve]

      # GET /api/v1/projects/:project_id/cost_items
      def index
        return unless authorize_action!('projects', 'read')

        items = @project.project_cost_items.not_deleted

        # Stats BEFORE filtering (for dashboard tiles)
        stats = {
          total_cost: items.sum(:amount),
          by_type: items.group(:cost_type).sum(:amount),
          by_status: items.group(:status).sum(:amount),
          by_category: items.where.not(category: [nil, '']).group(:category).sum(:amount),
          budget_amount: @project.budget_amount,
          budget_remaining: @project.budget_variance,
          over_budget: @project.over_budget?
        }

        # Filters
        items = items.by_phase(params[:phase_id])
        items = items.by_task(params[:task_id])
        items = items.by_type(params[:cost_type])
        items = items.by_status(params[:status])
        items = items.by_date_range(params[:start_date], params[:end_date])

        if params[:search].present?
          search_term = "%#{params[:search]}%"
          items = items.where(
            "description ILIKE ? OR vendor_name ILIKE ? OR invoice_number ILIKE ?",
            search_term, search_term, search_term
          )
        end

        # Sorting
        sort_by = params[:sort_by] || 'created_at'
        sort_order = params[:sort_order]&.downcase == 'asc' ? :asc : :desc
        allowed_sorts = %w[created_at date amount cost_type status vendor_name]
        sort_by = 'created_at' unless allowed_sorts.include?(sort_by)
        items = items.order(sort_by => sort_order)

        total_count = items.count
        page = (params[:page] || 1).to_i
        per_page = (params[:per_page] || 25).to_i
        items = items.offset((page - 1) * per_page).limit(per_page)

        render json: {
          cost_items: items.includes(:vendor, :bill).map { |item| serialize_cost_item(item) },
          stats: stats,
          posting: posting_options,
          meta: { total_count: total_count, page: page, per_page: per_page }
        }
      end

      # GET /api/v1/projects/:project_id/cost_items/duplicates?contractor_id=&amount=
      # Lines already on this job from the same vendor for the same amount.
      def duplicates
        return unless authorize_action!('projects', 'read')

        found = entry_service.duplicates(vendor_id: params[:contractor_id], amount: params[:amount], except_id: params[:except_id])
        render json: { duplicates: found.map { |item| serialize_cost_item(item) } }
      end

      # POST /api/v1/projects/:project_id/cost_items/:id/approve
      # Approves the draft bill behind the line (E109), as Post does in Bills.
      def approve
        return unless authorize_action!('projects', 'read')
        return unless authorize_action!('bills', 'update')

        entry_service.approve!(@cost_item)
        render json: serialize_cost_item(@cost_item.reload)
      rescue ProjectCostEntryService::Error => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # GET /api/v1/projects/:project_id/cost_items/:id
      def show
        return unless authorize_action!('projects', 'read')

        render json: serialize_cost_item(@cost_item, extra: %i[receipt_s3_key])
      end

      # POST /api/v1/projects/:project_id/cost_items
      def create
        return unless authorize_action!('projects', 'update')

        # Only used to fill in from a part; the line is built and saved by
        # ProjectCostEntryService.
        @cost_item = ProjectCostItem.new(cost_item_params)

        # Auto-populate from part if provided
        if @cost_item.part_id.present?
          part = @company.parts.find_by(id: @cost_item.part_id)
          if part
            @cost_item.unit_price ||= part.default_cost
            @cost_item.description = part.name if @cost_item.description.blank?
          end
        end

        pay_mode = params[:pay_mode].presence
        if pay_mode == 'paid'
          return unless authorize_action!('journal_entries', 'create')
        end

        attrs = cost_item_params.to_h.symbolize_keys
        if @cost_item.part_id.present?
          attrs[:unit_price] ||= @cost_item.unit_price
          attrs[:description] = @cost_item.description if attrs[:description].blank?
        end
        item = entry_service.create!(attrs, pay_mode: pay_mode, payment_account_id: params[:payment_account_id],
                                            category_account_id: params[:category_account_id])
        render json: serialize_cost_item(item), status: :created
      rescue ProjectCostEntryService::Error => e
        render json: { error: e.message, errors: [e.message] }, status: :unprocessable_entity
      rescue ActiveRecord::RecordInvalid => e
        render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
      end

      # PATCH/PUT /api/v1/projects/:project_id/cost_items/:id
      def update
        return unless authorize_action!('projects', 'update')

        attrs = cost_item_params
        # A line's status comes from its bill or its expense entry (E109).
        # Only tracking-only lines take a status from the form.
        if @cost_item.bill_id.present? || @cost_item.journal_entry_id.present?
          attrs = attrs.except(:status, :paid_at, :approved_by_id)
          if @cost_item.journal_entry_id.present? && attrs.key?(:amount) && attrs[:amount].to_d != @cost_item.amount.to_d
            return render json: { error: 'This cost is already in your books. Change the amount on its entry in Accounting.' },
                          status: :unprocessable_entity
          end
          if @cost_item.bill && @cost_item.bill.status != 'draft' && attrs.key?(:amount) && attrs[:amount].to_d != @cost_item.amount.to_d
            return render json: { error: "Bill #{@cost_item.bill.bill_number} is approved. Change the amount on the bill in Accounting, Bills." },
                          status: :unprocessable_entity
          end
        elsif attrs.key?(:status) && !attrs[:status].in?(%w[pending approved disputed])
          attrs = attrs.merge(status: 'approved')
        end

        if @cost_item.update(attrs)
          ProjectCostBillService.follow_cost_line!(@cost_item) if @cost_item.saved_change_to_amount?
          render json: serialize_cost_item(@cost_item)
        else
          render json: { errors: @cost_item.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # DELETE /api/v1/projects/:project_id/cost_items/:id
      def destroy
        return unless authorize_action!('projects', 'delete')

        entry_service.remove!(@cost_item)
        @cost_item.project.recalculate_costs!
        @cost_item.project_phase&.recalculate_costs! if @cost_item.project_phase_id.present?

        render json: { message: 'Cost item deleted' }
      rescue ProjectCostEntryService::Error => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # GET /api/v1/projects/:project_id/cost_items/summary
      def summary
        return unless authorize_action!('projects', 'read')

        items = @project.project_cost_items.not_deleted

        # Per-phase breakdown
        phases = @project.project_phases.map do |phase|
          phase_items = items.where(project_phase_id: phase.id)
          {
            id: phase.id,
            name: phase.name,
            estimated_budget: phase.estimated_budget,
            actual_cost: phase.actual_cost,
            committed_cost: phase_items.where(status: 'pending').sum(:amount),
            variance: phase.estimated_budget ? (phase.estimated_budget - (phase.actual_cost || 0) - phase_items.where(status: 'pending').sum(:amount)) : nil,
            by_type: phase_items.group(:cost_type).sum(:amount)
          }
        end

        # Unassigned costs (no phase)
        unassigned = items.where(project_phase_id: nil)

        # E109: do the phase budgets add up to the project budget?
        budgeted = @project.project_phases.map(&:estimated_budget).compact
        phase_budget_total = budgeted.any? ? budgeted.sum.to_d : nil

        render json: {
          project: {
            budget_amount: @project.budget_amount,
            actual_cost: @project.actual_cost,
            committed_cost: @project.committed_cost,
            projected_cost: @project.projected_cost,
            labor_cost: @project.labor_cost,
            materials_cost: @project.materials_cost,
            subcontractor_cost: @project.subcontractor_cost,
            other_cost: @project.other_cost,
            variance: @project.budget_variance,
            variance_percentage: @project.budget_variance_percentage,
            over_budget: @project.over_budget?,
            phase_budget_total: phase_budget_total,
            budget_not_on_phase: (@project.budget_amount && phase_budget_total ? @project.budget_amount - phase_budget_total : nil)
          },
          phases: phases,
          unassigned: {
            total: unassigned.sum(:amount),
            by_type: unassigned.group(:cost_type).sum(:amount)
          },
          by_type: items.group(:cost_type).sum(:amount),
          by_status: items.group(:status).sum(:amount),
          by_category: items.where.not(category: [nil, '']).group(:category).sum(:amount),
          customer_payments: customer_payments
        }
      end

      private

      # What the customer has paid on the project's deal (E78 step 8), from
      # the Deal Funding figures. Nil until the deal is approved.
      def customer_payments
        return nil unless @project.deal_id

        row = Reports::DealFundingReportService.new(@company).rows_for([@project.deal_id])[@project.deal_id]
        row&.slice(:deal_amount, :received, :owed, :overdue_amount, :next_draw, :status, :invoice_id, :invoice_number,
                   :lender_pending, :draws, :due_date)
      end

      def entry_service
        @entry_service ||= ProjectCostEntryService.new(@project, user: current_user)
      end

      # What the Add cost form may offer this person (E109).
      def posting_options
        on = ProjectCostEntryService.posting_on?(@company)
        can_expense = on && can?('journal_entries', 'create')
        out = { posts_to_books: on, can_record_expense: can_expense, can_approve_bills: on && can?('bills', 'update') }
        return out unless can_expense

        default = ProjectCostBillService.expense_account_for(@company, nil)
        out.merge(
          payment_accounts: @company.bank_accounts.where.not(chart_of_account_id: nil).order(:bank_name).map do |ba|
            { chart_of_account_id: ba.chart_of_account_id, name: ba.try(:bank_name) || ba.try(:name),
              last_four: ba.try(:display_last_four) || ba.try(:last_four) }
          end,
          expense_accounts: @company.chart_of_accounts.postable.where(account_type: 'expense').ordered
                                    .map { |a| { id: a.id, name: a.name, account_number: a.account_number } },
          default_expense_account_id: default&.id
        )
      end

      def set_project
        @project = @company.projects.not_deleted.find(params[:project_id])
      end

      def set_cost_item
        @cost_item = @project.project_cost_items.not_deleted.find(params[:id])
      end

      COST_ITEM_FIELDS = %i[id project_id project_phase_id project_task_id cost_type category
                            description vendor_name invoice_number amount quantity unit_price
                            date status paid_at approved_by_id notes receipt_url part_id
                            inventory_transaction_id bill_id metadata created_at updated_at].freeze

      # contractor_id is an alias of the vendor_id column, and as_json(only:)
      # skips aliases — so it is added by hand, or the edit form loses the vendor.
      def serialize_cost_item(item, extra: [])
        item.as_json(only: COST_ITEM_FIELDS + extra).merge(
          'contractor_id' => item.vendor_id,
          'contractor_name' => item.vendor&.name,
          'bill' => item.bill && {
            'id' => item.bill.id, 'bill_number' => item.bill.bill_number, 'status' => item.bill.status,
            'source' => item.bill.source, 'total_amount' => item.bill.total_amount
          },
          'pay_mode' => ProjectCostEntryService.pay_mode_for(item),
          'source_label' => ProjectCostEntryService.source_for(item),
          'journal_entry_id' => item.journal_entry_id
        )
      end

      def cost_item_params
        params.permit(
          :project_phase_id, :project_task_id, :cost_type, :category,
          :description, :vendor_name, :invoice_number, :amount, :quantity,
          :unit_price, :date, :status, :paid_at, :approved_by_id, :notes,
          :receipt_url, :receipt_s3_key, :part_id, :contractor_id, :inventory_transaction_id,
          metadata: {}
        )
      end
    end
  end
end
