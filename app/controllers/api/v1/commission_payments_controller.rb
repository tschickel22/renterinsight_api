# frozen_string_literal: true

module Api
  module V1
    class CommissionPaymentsController < ApplicationController
      before_action :set_company_scope
      before_action :set_payment, only: [:show, :update, :destroy, :approve, :mark_paid, :reverse, :undo_reversal, :statement]
      
      # GET /api/v1/commission-payments
      # GET /api/v1/deals/:deal_id/commissions
      def index
        return unless authorize_action!('commission_payments', 'read')
        
        payments = @company.commission_payments.active
        
        # CRITICAL: Only show commissions for GL-approved deals
        # Commissions are not available for approval/payment until the deal is GL-posted
        payments = payments.joins(:deal).where(deals: { gl_posted: true })
        
        # Filter by deal if nested route
        if params[:deal_id].present?
          payments = payments.where(deal_id: params[:deal_id])
        end
        
        # Filter by status
        if params[:status].present?
          payments = payments.where(status: params[:status])
        end
        
        # Filter by payee
        if params[:payee_user_id].present?
          payments = payments.for_payee(params[:payee_user_id])
        end
        
        # Filter by location
        if params[:location_id].present?
          payments = payments.where(location_id: params[:location_id])
        end
        
        # Filter by date range
        if params[:start_date].present? && params[:end_date].present?
          start_date = Date.parse(params[:start_date])
          end_date = Date.parse(params[:end_date])
          payments = payments.where('commission_payments.created_at >= ? AND commission_payments.created_at <= ?', start_date.beginning_of_day, end_date.end_of_day)
        end
        
        # Apply location selector filter
        payments = payments.for_current_location if Current.location_filtered?
        
        # Apply RBAC filtering
        if current_user.uses_rbac? && !current_user.effective_admin?
          location_ids = permission_service.accessible_location_ids
          payments = location_ids.any? ? 
            payments.where(location_id: location_ids) : 
            payments.none
        end
        
        # Count total before pagination
        total_count = payments.count
        
        # Order by date
        payments = payments.ordered
        
        # Pagination
        page = (params[:page] || 1).to_i
        per_page = (params[:per_page] || 50).to_i
        per_page = [per_page, 200].min # Max 200 per page
        
        payments = payments.offset((page - 1) * per_page).limit(per_page)
        
        render json: {
          payments: payments.map { |p| payment_json(p) },
          meta: {
            total: total_count,
            total_amount: @company.commission_payments.active.sum(:amount).round(2),
            page: page,
            per_page: per_page,
            total_pages: (total_count.to_f / per_page).ceil
          }
        }
      end
      
      # GET /api/v1/commission-payments/my-commissions
      # View current user's own commission payments (no admin permission required)
      def my_commissions
        # Any user can view their own commissions
        payments = @company.commission_payments.active.for_payee(current_user.id)
        
        # Filter by status if provided
        if params[:status].present?
          payments = payments.where(status: params[:status])
        end
        
        # Filter by date range
        if params[:start_date].present? && params[:end_date].present?
          start_date = Date.parse(params[:start_date])
          end_date = Date.parse(params[:end_date])
          payments = payments.where('created_at >= ? AND created_at <= ?', start_date.beginning_of_day, end_date.end_of_day)
        end
        
        # Count total before pagination
        total_count = payments.count
        
        # Order by date
        payments = payments.ordered
        
        # Pagination
        page = (params[:page] || 1).to_i
        per_page = (params[:per_page] || 50).to_i
        per_page = [per_page, 200].min # Max 200 per page
        
        payments = payments.offset((page - 1) * per_page).limit(per_page)
        
        render json: {
          payments: payments.map { |p| payment_json(p) },
          meta: {
            total: total_count,
            total_amount: @company.commission_payments.active.for_payee(current_user.id).sum(:amount).round(2),
            page: page,
            per_page: per_page,
            total_pages: (total_count.to_f / per_page).ceil
          }
        }
      end
      
      # GET /api/v1/commission-payments/stats
      def stats
        return unless authorize_action!('commission_payments', 'read')
        
        base_payments = @company.commission_payments.active
        # Only count commissions for GL-approved deals
        base_payments = base_payments.joins(:deal).where(deals: { gl_posted: true })
        base_payments = base_payments.for_current_location if Current.location_filtered?
        
        # Apply RBAC filtering
        if current_user.uses_rbac? && !current_user.effective_admin?
          location_ids = permission_service.accessible_location_ids
          base_payments = location_ids.any? ? 
            base_payments.where(location_id: location_ids) : 
            base_payments.none
        end
        
        render json: {
          pending: {
            count: base_payments.pending.count,
            amount: base_payments.pending.sum(:amount).round(2)
          },
          approved: {
            count: base_payments.approved.count,
            amount: base_payments.approved.sum(:amount).round(2)
          },
          paid: {
            count: base_payments.paid.count,
            amount: base_payments.paid.sum(:amount).round(2)
          },
          partially_paid: {
            count: base_payments.partially_paid.count,
            amount: base_payments.partially_paid.sum(:amount).round(2),
            amount_paid: base_payments.partially_paid.sum(:amount_paid).round(2),
            remaining: base_payments.partially_paid.sum(:remaining_balance).round(2)
          },
          total: {
            count: base_payments.count,
            amount: base_payments.sum(:amount).round(2)
          },
          this_month: {
            count: base_payments.where('commission_payments.created_at >= ?', Date.today.beginning_of_month).count,
            amount: base_payments.where('commission_payments.created_at >= ?', Date.today.beginning_of_month).sum(:amount).round(2)
          }
        }
      end
      
      # GET /api/v1/commission-payments/dashboard
      # Comprehensive dashboard data for finance/management view
      def dashboard
        return unless authorize_action!('commission_payments', 'read')
        
        base_payments = @company.commission_payments.active
        # Only count commissions for GL-approved deals
        base_payments = base_payments.joins(:deal).where(deals: { gl_posted: true })
        base_payments = base_payments.for_current_location if Current.location_filtered?
        if current_user.uses_rbac? && !current_user.effective_admin?
          location_ids = permission_service.accessible_location_ids
          base_payments = location_ids.any? ? 
            base_payments.where(location_id: location_ids) : 
            base_payments.none
        end
        
        # Calculate date ranges
        today = Date.today
        this_month_start = today.beginning_of_month
        last_month_start = (today - 1.month).beginning_of_month
        last_month_end = last_month_start.end_of_month
        
        # Top-level stats
        pending_payments = base_payments.pending
        approved_payments = base_payments.approved
        paid_payments = base_payments.paid
        this_month_payments = base_payments.where('commission_payments.created_at >= ?', this_month_start)
        last_month_payments = base_payments.where('commission_payments.created_at >= ? AND commission_payments.created_at <= ?', last_month_start, last_month_end)
        
        # Calculate month-over-month change
        this_month_total = this_month_payments.sum(:amount)
        last_month_total = last_month_payments.sum(:amount)
        expense_change_pct = last_month_total > 0 ? (((this_month_total - last_month_total) / last_month_total) * 100).round(1) : 0
        
        # Top Earners (Top 10 employees by total commission)
        # Note: User.name is a computed method (first_name + last_name), so we must construct it in SQL
        top_earners_sql = <<-SQL
          SELECT 
            commission_payments.payee_user_id,
            COALESCE(
              NULLIF(TRIM(CONCAT(users.first_name, ' ', users.last_name)), ''),
              users.email,
              'Unknown Employee'
            ) as user_name,
            COUNT(commission_payments.id) as deal_count,
            COALESCE(SUM(commission_payments.amount), 0) as total_earned,
            COALESCE(AVG(commission_payments.amount), 0) as avg_per_deal
          FROM commission_payments
          LEFT JOIN users ON users.id = commission_payments.payee_user_id
          WHERE commission_payments.company_id = #{@company.id}
            AND commission_payments.payee_user_id IS NOT NULL
            AND (commission_payments.is_deleted IS NULL OR commission_payments.is_deleted = false)
        SQL
        
        # Add location filter if needed
        if Current.location_filtered?
          top_earners_sql += " AND commission_payments.location_id = #{Current.location_id}"
        end
        
        # Add RBAC filter if needed
        if current_user.uses_rbac? && !current_user.effective_admin?
          location_ids = permission_service.accessible_location_ids
          if location_ids.any?
            top_earners_sql += " AND commission_payments.location_id IN (#{location_ids.join(',')})"
          else
            # No accessible locations - return empty array
            top_earners = []
            top_earners_sql = nil
          end
        end
        
        if top_earners_sql
          top_earners_sql += <<-SQL
            GROUP BY commission_payments.payee_user_id, users.first_name, users.last_name, users.email
            ORDER BY total_earned DESC
            LIMIT 10
          SQL
          
          results = ActiveRecord::Base.connection.execute(top_earners_sql)
          
          top_earners = results.map do |row|
            {
              userId: row['payee_user_id'],
              userName: row['user_name'],
              dealCount: row['deal_count'].to_i,
              totalEarned: row['total_earned'].to_f.round(2),
              avgPerDeal: row['avg_per_deal'].to_f.round(2)
            }
          end
        end
        
        # Status Breakdown (for pie/donut chart)
        status_breakdown = {
          pending: {
            count: pending_payments.count,
            amount: pending_payments.sum(:amount).round(2)
          },
          approved: {
            count: approved_payments.count,
            amount: approved_payments.sum(:amount).round(2)
          },
          paid: {
            count: paid_payments.count,
            amount: paid_payments.sum(:amount).round(2)
          }
        }
        
        # Payment Timeline (last 6 months)
        timeline = (0..5).reverse_each.map do |months_ago|
          month_start = (today - months_ago.months).beginning_of_month
          month_end = month_start.end_of_month
          month_payments = base_payments.where('commission_payments.created_at >= ? AND commission_payments.created_at <= ?', month_start, month_end)
          
          {
            month: month_start.strftime('%b %Y'),
            count: month_payments.count,
            amount: month_payments.sum(:amount).round(2),
            paid: month_payments.paid.sum(:amount).round(2)
          }
        end
        
        render json: {
          stats: {
            pendingApproval: {
              count: pending_payments.count,
              amount: pending_payments.sum(:amount).round(2)
            },
            toBePaid: {
              count: approved_payments.count,
              amount: approved_payments.sum(:amount).round(2)
            },
            paidThisMonth: {
              count: this_month_payments.paid.count,
              amount: this_month_payments.paid.sum(:amount).round(2)
            },
            expenseTrend: {
              changePercent: expense_change_pct,
              direction: expense_change_pct > 0 ? 'up' : expense_change_pct < 0 ? 'down' : 'same',
              thisMonth: this_month_total.round(2),
              lastMonth: last_month_total.round(2)
            }
          },
          topEarners: top_earners,
          statusBreakdown: status_breakdown,
          timeline: timeline
        }
      end
      
      # GET /api/v1/commission-payments/reports-data
      # Comprehensive reporting data for exports
      def reports_data
        return unless authorize_action!('commission_payments', 'read')
        
        # Parse date range
        start_date = params[:start_date].present? ? Date.parse(params[:start_date]) : Date.today.beginning_of_year
        end_date = params[:end_date].present? ? Date.parse(params[:end_date]) : Date.today
        
        base_payments = @company.commission_payments
          .active
          .where('paid_at >= ? AND paid_at <= ?', start_date.beginning_of_day, end_date.end_of_day)
          .where(status: ['paid', 'partially_paid'])
        
        base_payments = base_payments.for_current_location if Current.location_filtered?
        
        # Apply RBAC filtering
        if current_user.uses_rbac? && !current_user.effective_admin?
          location_ids = permission_service.accessible_location_ids
          base_payments = location_ids.any? ? 
            base_payments.where(location_id: location_ids) : 
            base_payments.none
        end
        
        # users.name can be NULL for some accounts; fall back to first+last, then email,
        # so the frontend always has a non-empty userName to render.
        user_name_sql = "COALESCE(NULLIF(TRIM(users.name), ''), " \
                        "NULLIF(TRIM(CONCAT_WS(' ', users.first_name, users.last_name)), ''), " \
                        "users.email)"

        # Payroll Export Data - Group by user and pay period
        payroll_data = base_payments
          .joins(:payee_user)
          .group('users.id', 'users.name', 'users.first_name', 'users.last_name', 'users.email')
          .select(
            'users.id as user_id',
            "#{user_name_sql} as user_name",
            'users.email as user_email',
            'COUNT(commission_payments.id) as payment_count',
            'COALESCE(SUM(commission_payments.amount_paid), 0) as total_paid',
            'COALESCE(SUM(commission_payments.amount - commission_payments.amount_paid), 0) as total_remaining'
          )
          .map do |record|
            {
              userId: record.user_id,
              userName: record.user_name,
              userEmail: record.user_email,
              paymentCount: record.payment_count,
              totalPaid: record.total_paid.round(2),
              totalRemaining: record.total_remaining.round(2),
              netPay: record.total_paid.round(2) # In real scenario, deductions would be calculated here
            }
          end

        # Tax Reporting (1099) - Annual totals
        tax_data = base_payments
          .joins(:payee_user)
          .group('users.id', 'users.name', 'users.first_name', 'users.last_name', 'users.email')
          .select(
            'users.id as user_id',
            "#{user_name_sql} as user_name",
            'users.email as user_email',
            'COUNT(commission_payments.id) as payment_count',
            'COALESCE(SUM(commission_payments.amount_paid), 0) as total_paid'
          )
          .map do |record|
            {
              userId: record.user_id,
              userName: record.user_name,
              userEmail: record.user_email,
              paymentCount: record.payment_count,
              totalPaid: record.total_paid.round(2),
              taxYear: start_date.year
            }
          end
        
        # Component Effectiveness - Which commission types pay out most
        component_stats = {}
        base_payments.each do |payment|
          next unless payment.line_items.is_a?(Array)
          
          payment.line_items.each do |item|
            component_type = item['component_type'] || 'unknown'
            component_stats[component_type] ||= { count: 0, total_amount: 0 }
            component_stats[component_type][:count] += 1
            component_stats[component_type][:total_amount] += (item['amount'] || 0).to_f
          end
        end
        
        component_effectiveness = component_stats.map do |type, data|
          {
            componentType: type.titleize,
            count: data[:count],
            totalAmount: data[:total_amount].round(2),
            avgAmount: (data[:total_amount] / data[:count]).round(2)
          }
        end.sort_by { |c| -c[:totalAmount] }
        
        # Location Comparison
        location_stats = base_payments
          .joins(:location)
          .group('locations.id', 'locations.name')
          .select(
            'locations.id as location_id',
            'locations.name as location_name',
            'COUNT(commission_payments.id) as payment_count',
            'COALESCE(SUM(commission_payments.amount_paid), 0) as total_paid'
          )
          .map do |record|
            {
              locationId: record.location_id,
              locationName: record.location_name,
              paymentCount: record.payment_count,
              totalPaid: record.total_paid.round(2)
            }
          end
        
        # Monthly Trends (last 12 months)
        monthly_trends = (0..11).reverse_each.map do |months_ago|
          month_start = (Date.today - months_ago.months).beginning_of_month
          month_end = month_start.end_of_month
          
          month_payments = @company.commission_payments
            .active
            .where('paid_at >= ? AND paid_at <= ?', month_start.beginning_of_day, month_end.end_of_day)
            .where(status: ['paid', 'partially_paid'])
          
          {
            month: month_start.strftime('%b %Y'),
            paymentCount: month_payments.count,
            totalPaid: month_payments.sum(:amount_paid).round(2),
            avgPayment: month_payments.count > 0 ? (month_payments.sum(:amount_paid) / month_payments.count).round(2) : 0
          }
        end
        
        render json: {
          dateRange: {
            startDate: start_date.iso8601,
            endDate: end_date.iso8601
          },
          payrollData: payroll_data,
          taxData: tax_data,
          componentEffectiveness: component_effectiveness,
          locationStats: location_stats,
          monthlyTrends: monthly_trends,
          summary: {
            totalPayments: base_payments.count,
            totalPaid: base_payments.sum(:amount_paid).round(2),
            uniquePayees: base_payments.select(:payee_user_id).distinct.count
          }
        }
      end
      
      # GET /api/v1/commission-payments/:id
      def show
        return unless authorize_action!('commission_payments', 'read')
        
        render json: { payment: payment_json(@payment, detailed: true) }
      end
      
      # GET /api/v1/commission-payments/:id/statement
      # Returns comprehensive statement data for PDF generation
      # If payment has a payment_reference, includes ALL payments with same reference
      def statement
        # Users can view their own statements OR admins can view any statement
        unless @payment.payee_user_id == current_user.id || authorize_action!('commission_payments', 'read')
          render json: { error: 'Unauthorized' }, status: :forbidden
          return
        end
        
        # Find all related payments (payments paid together with same check/reference)
        if @payment.payment_reference.present?
          # Include all payments with same payment_reference for this salesperson
          related_payments = @company.commission_payments
            .where(payee_user_id: @payment.payee_user_id)
            .where(payment_reference: @payment.payment_reference)
            .includes(:deal, :location)
            .order(:created_at)
        else
          # Single payment (not yet paid or no reference)
          related_payments = [@payment]
        end
        
        # Calculate totals across all related payments
        total_amount = related_payments.sum(&:amount)
        total_amount_paid = related_payments.sum(&:amount_paid)
        total_remaining = related_payments.sum(&:remaining_balance)
        
        statement_data = {
          # Summary info (uses first payment's data for reference)
          payment: {
            payment_reference: @payment.payment_reference,
            payment_method: @payment.payment_method&.titleize,
            paid_date: @payment.paid_date,
            paid_at: @payment.paid_at,
            status: @payment.display_status,
            
            # Totals across all related payments
            total_amount: total_amount,
            total_amount_paid: total_amount_paid,
            total_remaining_balance: total_remaining,
            
            # Count of payments included
            payment_count: related_payments.count
          },
          
          salesperson: {
            name: @payment.payee_user&.name,
            email: @payment.payee_user&.email,
            phone: @payment.payee_user&.phone
          },
          
          # Array of all payments with their deals
          payments: related_payments.map do |payment|
            {
              payment_number: payment.payment_number,
              amount: payment.amount,
              amount_paid: payment.amount_paid,
              remaining_balance: payment.remaining_balance,
              status: payment.display_status,
              created_at: payment.created_at,
              
              deal: payment.deal ? {
                name: payment.deal.name,
                customer_name: payment.deal.customer_display_name,
                stage: payment.deal.stage&.titleize,
                selling_price: payment.deal.selling_price,
                delivery_date: payment.deal.delivery_date,
                closed_date: payment.deal.won_at || payment.deal.actual_close_date
              } : nil,
              
              commission_breakdown: payment.line_items || [],
              deal_economics: payment.deal_economics || {}
            }
          end,
          
          location: @payment.location ? {
            name: @payment.location.name,
            address: @payment.location.address_line1,
            city: @payment.location.city,
            state: @payment.location.state,
            zip: @payment.location.zip_code,
            phone: @payment.location.phone
          } : nil,
          
          company: {
            name: @company.name,
            logo_url: @company.branding_settings&.dig('logo'),
            address: @company.respond_to?(:street) ? @company.street : nil,
            city: @company.respond_to?(:city) ? @company.city : nil,
            state: @company.respond_to?(:state) ? @company.state : nil,
            zip: @company.respond_to?(:zip) ? @company.zip : nil,
            phone: @company.respond_to?(:phone) ? @company.phone : nil,
            email: @company.respond_to?(:email) ? @company.email : nil
          },
          
          generated_at: Time.current.iso8601
        }
        
        render json: statement_data
      end
      
      # POST /api/v1/commission-payments
      def create
        return unless authorize_action!('commission_payments', 'create')
        
        payment = @company.commission_payments.build(payment_params)
        
        # Auto-assign location_id if filtered
        payment.location_id ||= Current.location_id if Current.location_id.present?
        
        if payment.save
          render json: { payment: payment_json(payment, detailed: true) }, status: :created
        else
          render json: { errors: payment.errors.full_messages }, status: :unprocessable_entity
        end
      end
      
      # PATCH /api/v1/commission-payments/:id
      def update
        return unless authorize_action!('commission_payments', 'update')
        
        if @payment.update(payment_params)
          render json: { payment: payment_json(@payment, detailed: true) }
        else
          render json: { errors: @payment.errors.full_messages }, status: :unprocessable_entity
        end
      end
      
      # DELETE /api/v1/commission-payments/:id
      def destroy
        return unless authorize_action!('commission_payments', 'delete')
        
        @payment.update!(is_deleted: true, deleted_at: Time.current)
        head :no_content
      end
      
      # POST /api/v1/commission-payments/:id/approve
      def approve
        return unless authorize_action!('commission_payments', 'approve')
        
        # CRITICAL: Commission cannot be approved until deal is GL-posted
        if @payment.deal && !@payment.deal.gl_posted?
          render json: { error: 'Cannot approve commission: deal has not been GL-approved yet. Approve the deal first in Accounting > Deals & Commissions.' }, status: :unprocessable_entity
          return
        end
        
        if @payment.approve!(approved_by: current_user)
          render json: { payment: payment_json(@payment, detailed: true) }
        else
          render json: { error: 'Cannot approve payment' }, status: :unprocessable_entity
        end
      end
      
      # POST /api/v1/commission-payments/:id/mark-paid
      def mark_paid
        return unless authorize_action!('commission_payments', 'mark_paid')
        
        unless params[:payment_method].present?
          render json: { error: 'payment_method is required' }, status: :bad_request
          return
        end
        
        # Parse paid_date if provided
        paid_date = params[:paid_date].present? ? Date.parse(params[:paid_date]) : Date.today
        
        if @payment.mark_paid!(
          paid_by: current_user,
          payment_method: params[:payment_method],
          payment_reference: params[:payment_reference],
          amount_paid: params[:amount_paid],
          paid_date: paid_date
        )
          render json: { payment: payment_json(@payment, detailed: true) }
        else
          render json: { error: 'Cannot mark payment as paid' }, status: :unprocessable_entity
        end
      end
      
      # POST /api/v1/commission-payments/:id/reverse
      def reverse
        return unless authorize_action!('commission_payments', 'reverse')
        
        unless params[:reason].present?
          render json: { error: 'reason is required' }, status: :bad_request
          return
        end
        
        if @payment.reverse!(reversed_by: current_user, reason: params[:reason])
          render json: { payment: payment_json(@payment, detailed: true) }
        else
          render json: { error: 'Cannot reverse payment' }, status: :unprocessable_entity
        end
      end
      
      # POST /api/v1/commission-payments/:id/undo-reversal
      def undo_reversal
        return unless authorize_action!('commission_payments', 'reverse')
        
        if @payment.undo_reversal!
          render json: { payment: payment_json(@payment, detailed: true) }
        else
          render json: { error: 'Cannot undo reversal' }, status: :unprocessable_entity
        end
      end
      
      # POST /api/v1/commission-payments/bulk-approve
      def bulk_approve
        return unless authorize_action!('commission_payments', 'approve')
        
        payment_ids = params[:payment_ids] || []
        
        if payment_ids.empty?
          render json: { error: 'payment_ids required' }, status: :bad_request
          return
        end
        
        payments = @company.commission_payments.where(id: payment_ids, status: 'pending')
        
        approved_count = 0
        errors = []
        
        payments.each do |payment|
          if payment.approve!(approved_by: current_user)
            approved_count += 1
          else
            errors << "Payment #{payment.payment_number}: #{payment.errors.full_messages.join(', ')}"
          end
        end
        
        render json: {
          approved_count: approved_count,
          errors: errors
        }
      end
      
      # POST /api/v1/commission-payments/bulk-mark-paid
      # Quick bulk payment - applies same details to all selected payments
      def bulk_mark_paid
        return unless authorize_action!('commission_payments', 'mark_paid')
        
        payment_ids = params[:payment_ids] || []
        payment_method = params[:payment_method]
        payment_reference = params[:payment_reference]
        paid_date = params[:paid_date].present? ? Date.parse(params[:paid_date]) : Date.today
        
        if payment_ids.empty? || payment_method.blank?
          render json: { error: 'payment_ids and payment_method required' }, status: :bad_request
          return
        end
        
        payments = @company.commission_payments.where(id: payment_ids, status: 'approved')
        
        paid_count = 0
        errors = []
        
        payments.each do |payment|
          if payment.mark_paid!(
            paid_by: current_user, 
            payment_method: payment_method, 
            payment_reference: payment_reference,
            paid_date: paid_date,
            amount_paid: payment.amount  # Full payment
          )
            paid_count += 1
          else
            errors << "Payment #{payment.payment_number}: #{payment.errors.full_messages.join(', ')}"
          end
        end
        
        render json: {
          paid_count: paid_count,
          errors: errors
        }
      end
      
      # POST /api/v1/commission-payments/bulk-mark-paid-detailed
      # Detailed bulk payment - individual details per payment (supports partial payments)
      # Body: { payments: [{ id: 1, amount_paid: 1200, payment_method: 'ach', payment_reference: 'TXN-123', paid_date: '2026-01-08' }] }
      def bulk_mark_paid_detailed
        return unless authorize_action!('commission_payments', 'mark_paid')
        
        payments_data = params[:payments] || []
        
        if payments_data.empty?
          render json: { error: 'payments array required' }, status: :bad_request
          return
        end
        
        paid_count = 0
        partial_count = 0
        errors = []
        
        payments_data.each do |payment_data|
          payment = @company.commission_payments.find_by(id: payment_data[:id], status: 'approved')
          
          unless payment
            errors << "Payment ID #{payment_data[:id]}: Not found or not approved"
            next
          end
          
          amount_paid = payment_data[:amount_paid].to_f
          paid_date = payment_data[:paid_date].present? ? Date.parse(payment_data[:paid_date]) : Date.today
          
          # Skip if amount_paid is 0 or negative
          if amount_paid <= 0
            errors << "Payment #{payment.payment_number}: Invalid amount_paid (#{amount_paid})"
            next
          end
          
          is_partial = amount_paid < payment.amount
          
          if payment.mark_paid!(
            paid_by: current_user,
            payment_method: payment_data[:payment_method],
            payment_reference: payment_data[:payment_reference],
            amount_paid: amount_paid,
            paid_date: paid_date
          )
            is_partial ? partial_count += 1 : paid_count += 1
          else
            errors << "Payment #{payment.payment_number}: #{payment.errors.full_messages.join(', ')}"
          end
        end
        
        render json: {
          paid_count: paid_count,
          partial_count: partial_count,
          total_processed: paid_count + partial_count,
          errors: errors
        }
      end
      
      # POST /api/v1/commission-payments/generate-for-deal
      def generate_for_deal
        return unless authorize_action!('commission_payments', 'create')
        
        deal_id = params[:deal_id]
        
        unless deal_id.present?
          render json: { error: 'deal_id required' }, status: :bad_request
          return
        end
        
        deal = @company.deals.find(deal_id)
        
        # Commission payments cannot be generated until deal is GL-posted
        unless deal.gl_posted?
          render json: { error: 'Cannot generate commission: deal has not been GL-approved yet' }, status: :unprocessable_entity
          return
        end
        
        payment = CommissionPaymentGeneratorService.generate_for_deal(deal)
        
        if payment.present?
          render json: { payment: payment_json(payment, detailed: true) }, status: :created
        else
          render json: { error: 'Could not generate payment (deal not delivered or payment already exists)' }, status: :unprocessable_entity
        end
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Deal not found' }, status: :not_found
      end
      
      # POST /api/v1/commission-payments/export
      # Export selected payments to CSV
      def export
        return unless authorize_action!('commission_payments', 'read')
        
        unless params[:payment_ids].present?
          render json: { error: 'payment_ids required' }, status: :bad_request
          return
        end
        
        payment_ids = params[:payment_ids]
        payments = @company.commission_payments.where(id: payment_ids).includes(:deal, :payee_user, :location, :approved_by_user, :paid_by_user).order(:created_at)
        
        # Apply RBAC filtering
        if current_user.uses_rbac? && !current_user.effective_admin?
          location_ids = permission_service.accessible_location_ids
          payments = location_ids.any? ? 
            payments.where(location_id: location_ids) : 
            payments.none
        end
        
        require 'csv'
        
        csv_data = CSV.generate(headers: true) do |csv|
          # Header row
          csv << [
            'Payment Number',
            'Salesperson',
            'Deal',
            'Amount',
            'Amount Paid',
            'Remaining Balance',
            'Status',
            'Approved By',
            'Approved At',
            'Paid By',
            'Paid At',
            'Payment Method',
            'Payment Reference',
            'Location',
            'Created At',
            'Notes'
          ]
          
          # Data rows
          payments.each do |payment|
            csv << [
              payment.payment_number,
              payment.payee_user&.name,
              payment.deal&.name,
              format('%.2f', payment.amount),
              format('%.2f', payment.amount_paid),
              format('%.2f', payment.remaining_balance),
              payment.display_status,
              payment.approved_by_user&.name,
              payment.approved_at&.strftime('%m/%d/%Y %I:%M %p'),
              payment.paid_by_user&.name,
              payment.paid_at&.strftime('%m/%d/%Y %I:%M %p'),
              payment.payment_method&.titleize,
              payment.payment_reference,
              payment.location&.name,
              payment.created_at.strftime('%m/%d/%Y %I:%M %p'),
              payment.notes
            ]
          end
        end
        
        # Send CSV file
        send_data csv_data,
          filename: "commission_payments_#{Date.today.strftime('%Y%m%d')}.csv",
          type: 'text/csv',
          disposition: 'attachment'
      end
      
      # GET /api/v1/commission-payments/preview-for-deal/:deal_id
      # POST /api/v1/deals/:deal_id/commissions/preview
      def preview_for_deal
        return unless authorize_action!('commission_payments', 'read')
        
        deal_id = params[:deal_id]
        
        unless deal_id.present?
          render json: { error: 'deal_id required' }, status: :bad_request
          return
        end
        
        deal = @company.deals.find(deal_id)
        preview = CommissionPaymentGeneratorService.preview_for_deal(deal)
        
        render json: preview
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Deal not found' }, status: :not_found
      end
      
      # Alias for nested route
      alias_method :preview, :preview_for_deal
      
      private
      
      def set_payment
        @payment = @company.commission_payments.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Payment not found' }, status: :not_found
      end
      
      def payment_params
        params.require(:payment).permit(
          :deal_id,
          :payee_user_id,
          :amount,
          :status,
          :notes,
          :payment_method,
          :payment_reference,
          :location_id
        )
      end
      
      def payment_json(payment, detailed: false)
        base = {
          id: payment.id,
          paymentNumber: payment.payment_number,
          status: payment.status,
          displayStatus: payment.display_status,
          amount: payment.amount,
          amountPaid: payment.amount_paid,
          remainingBalance: payment.remaining_balance,
          
          # Relationships
          dealId: payment.deal_id,
          dealName: payment.deal&.name,
          dealGlPosted: payment.deal&.gl_posted || false,
          payeeUserId: payment.payee_user_id,
          payeeName: payment.payee_user&.name,
          locationId: payment.location_id,
          locationName: payment.location&.name,
          
          # Workflow
          approvedAt: payment.approved_at&.iso8601,
          approvedBy: payment.approved_by_user&.name,
          paidAt: payment.paid_at&.iso8601,
          paidDate: payment.paid_date&.iso8601,
          paidBy: payment.paid_by_user&.name,
          paymentMethod: payment.payment_method,
          paymentReference: payment.payment_reference,
          
          # Reversal
          isReversed: payment.is_reversed,
          reversedAt: payment.reversed_at&.iso8601,
          reversedBy: payment.reversed_by_user&.name,
          reversalReason: payment.reversal_reason,
          
          # Status checks
          canApprove: payment.can_approve?,
          canMarkPaid: payment.can_mark_paid?,
          canReverse: payment.can_reverse?,
          canUndoReversal: payment.can_undo_reversal?,
          
          createdAt: payment.created_at&.iso8601,
          updatedAt: payment.updated_at&.iso8601
        }
        
        if detailed
          base[:notes] = payment.notes
          base[:calculationDetails] = payment.calculation_details
          base[:lineItems] = payment.line_items
          base[:dealEconomics] = payment.deal_economics
        end
        
        base
      end
    end
  end
end
