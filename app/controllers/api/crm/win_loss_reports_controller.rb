module Api
  module Crm
    class WinLossReportsController < ApplicationController
      include RbacAuthorization
      rbac_resource :reports, read_actions: [:index, :show, :summary, :trends]

      before_action :set_company_scope
      before_action :set_deal, except: [:index, :summary, :trends]
      before_action :set_report, only: [:show, :update, :destroy]

      # GET /api/crm/win_loss_reports
      def index
        # Scope reports to this company's deals only
        deal_ids = @company.deals.pluck(:id)
        reports = WinLossReport.where(deal_id: deal_ids)
                              .includes(:deal, :user)
                              .order(created_at: :desc)
        
        # Filter by result if provided
        reports = reports.where(result: params[:result]) if params[:result].present?
        
        # Filter by date range
        if params[:start_date].present?
          reports = reports.where('win_loss_reports.created_at >= ?', params[:start_date])
        end
        
        if params[:end_date].present?
          reports = reports.where('win_loss_reports.created_at <= ?', params[:end_date])
        end
        
        render json: reports.map { |r| report_json(r) }
      end

      # GET /api/crm/win_loss_reports/summary
      def summary
        start_date = params[:start_date]&.to_date || 90.days.ago
        end_date = params[:end_date]&.to_date || Date.today
        
        # Scope to this company's deals
        deal_ids = @company.deals.pluck(:id)
        reports = WinLossReport.where(deal_id: deal_ids, created_at: start_date..end_date)
        
        won_reports = reports.where(result: 'won')
        lost_reports = reports.where(result: 'lost')
        
        # Top win reasons
        win_reasons = won_reports.group(:primary_reason)
                                .count
                                .sort_by { |_, count| -count }
                                .first(5)
        
        # Top loss reasons
        loss_reasons = lost_reports.group(:primary_reason)
                                  .count
                                  .sort_by { |_, count| -count }
                                  .first(5)
        
        # Competitor analysis
        competitors = lost_reports.where.not(competitor: [nil, ''])
                                .group(:competitor)
                                .count
                                .sort_by { |_, count| -count }
                                .first(5)
        
        total_won = won_reports.count
        total_lost = lost_reports.count
        total = total_won + total_lost
        
        render json: {
          period: {
            startDate: start_date.iso8601,
            endDate: end_date.iso8601
          },
          totals: {
            won: total_won,
            lost: total_lost,
            winRate: total > 0 ? (total_won.to_f / total * 100).round(2) : 0
          },
          wonValue: @company.deals.where(id: won_reports.pluck(:deal_id)).sum(:value),
          lostValue: @company.deals.where(id: lost_reports.pluck(:deal_id)).sum(:value),
          topWinReasons: win_reasons.map { |reason, count| { reason: reason, count: count } },
          topLossReasons: loss_reasons.map { |reason, count| { reason: reason, count: count } },
          topCompetitors: competitors.map { |competitor, count| { name: competitor, count: count } }
        }
      end

      # GET /api/crm/win_loss_reports/trends
      def trends
        period = params[:period] || 'month' # day, week, month, quarter
        limit = params[:limit]&.to_i || 12
        
        # PostgreSQL date formatting (not SQLite strftime)
        date_format = case period
        when 'day'
          'YYYY-MM-DD'
        when 'week'
          'IYYY-IW'
        when 'quarter'
          'YYYY-"Q"Q'
        else
          'YYYY-MM'
        end
        
        # Scope to this company's deals
        deal_ids = @company.deals.pluck(:id)
        reports = WinLossReport.where(deal_id: deal_ids)
                              .where('win_loss_reports.created_at >= ?', limit.send(period.pluralize).ago)
        
        trends_data = reports.group(Arel.sql("to_char(created_at, '#{date_format}')"))
                            .group(:result)
                            .count
        
        # Organize by period
        periods = {}
        trends_data.each do |(period_key, result), count|
          periods[period_key] ||= { period: period_key, won: 0, lost: 0 }
          periods[period_key][result.to_sym] = count
        end
        
        render json: {
          period: period,
          data: periods.values.sort_by { |p| p[:period] }
        }
      end

      # GET /api/crm/deals/:deal_id/win_loss_report
      def show
        render json: report_json(@report, detailed: true)
      end

      # POST /api/crm/deals/:deal_id/win_loss_report
      def create
        report = @deal.build_win_loss_report(report_params)
        report.user_id = current_user&.id
        
        if report.save
          render json: report_json(report, detailed: true), status: :created
        else
          render json: { errors: report.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # PATCH/PUT /api/crm/deals/:deal_id/win_loss_report
      def update
        if @report.update(report_params)
          render json: report_json(@report, detailed: true)
        else
          render json: { errors: @report.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # DELETE /api/crm/deals/:deal_id/win_loss_report
      def destroy
        @report.destroy
        head :no_content
      end

      private

      def set_company_scope
        unless current_user
          Rails.logger.error "🚫 [WinLossReportsController] No authenticated user found"
          render json: { error: 'Authentication required' }, status: :unauthorized
          return
        end
        
        company_id = current_company_id
        
        unless company_id.present?
          Rails.logger.error "🚫 [WinLossReportsController] No company context available"
          render json: { error: 'No company context' }, status: :forbidden
          return
        end
        
        @company = ::Company.find_by(id: company_id)
        
        if @company.nil?
          Rails.logger.error "🚫 [WinLossReportsController] Company #{company_id} not found"
          render json: { error: 'Company not found' }, status: :not_found
          return
        end
        
        Rails.logger.info "✅ [WinLossReportsController] Company scope set: #{@company.name} (ID: #{@company.id})"
      end

      def set_deal
        @deal = @company.deals.find_by(id: params[:deal_id])
        unless @deal
          render json: { error: 'Deal not found or access denied' }, status: :not_found
          return
        end
      end

      def set_report
        @report = @deal.win_loss_report
        
        if @report.nil?
          render json: { error: 'Win/Loss report not found for this deal' }, status: :not_found
        end
      end

      def report_params
        params.require(:win_loss_report).permit(
          :result, :primary_reason, :secondary_reason, :competitor,
          :competitive_advantage, :competitive_disadvantage,
          :customer_feedback, :internal_notes, :lessons_learned,
          :deal_quality_score, :sales_process_score, :product_fit_score
        )
      end

      def report_json(report, detailed: false)
        base = {
          id: report.id,
          dealId: report.deal_id,
          result: report.result,
          primaryReason: report.primary_reason,
          secondaryReason: report.secondary_reason,
          competitor: report.competitor,
          competitiveAdvantage: report.competitive_advantage,
          competitiveDisadvantage: report.competitive_disadvantage,
          dealQualityScore: report.deal_quality_score,
          salesProcessScore: report.sales_process_score,
          productFitScore: report.product_fit_score,
          userId: report.user_id,
          userName: report.user&.name,
          createdAt: report.created_at&.iso8601,
          updatedAt: report.updated_at&.iso8601
        }
        
        if detailed
          base.merge!(
            customerFeedback: report.customer_feedback,
            internalNotes: report.internal_notes,
            lessonsLearned: report.lessons_learned,
            deal: {
              id: report.deal.id,
              name: report.deal.name,
              value: report.deal.value,
              stage: report.deal.stage,
              accountName: report.deal.account&.name
            }
          )
        end
        
        base
      end
    end
  end
end
