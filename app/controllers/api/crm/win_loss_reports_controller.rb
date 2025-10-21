module Api
  module Crm
    class WinLossReportsController < ApplicationController
      before_action :set_deal, except: [:index, :summary, :trends]
      before_action :set_report, only: [:show, :update, :destroy]

      # GET /api/crm/win_loss_reports
      def index
        reports = WinLossReport.includes(:deal, :user)
                              .order(created_at: :desc)
        
        # Filter by result if provided
        reports = reports.where(result: params[:result]) if params[:result].present?
        
        # Filter by date range
        if params[:start_date].present?
          reports = reports.where('created_at >= ?', params[:start_date])
        end
        
        if params[:end_date].present?
          reports = reports.where('created_at <= ?', params[:end_date])
        end
        
        render json: reports.map { |r| report_json(r) }
      end

      # GET /api/crm/win_loss_reports/summary
      def summary
        start_date = params[:start_date]&.to_date || 90.days.ago
        end_date = params[:end_date]&.to_date || Date.today
        
        reports = WinLossReport.where(created_at: start_date..end_date)
        
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
        
        render json: {
          period: {
            startDate: start_date.iso8601,
            endDate: end_date.iso8601
          },
          totals: {
            won: won_reports.count,
            lost: lost_reports.count,
            winRate: (won_reports.count.to_f / (won_reports.count + lost_reports.count) * 100).round(2)
          },
          wonValue: Deal.where(id: won_reports.pluck(:deal_id)).sum(:value),
          lostValue: Deal.where(id: lost_reports.pluck(:deal_id)).sum(:value),
          topWinReasons: win_reasons.map { |reason, count| { reason: reason, count: count } },
          topLossReasons: loss_reasons.map { |reason, count| { reason: reason, count: count } },
          topCompetitors: competitors.map { |competitor, count| { name: competitor, count: count } }
        }
      end

      # GET /api/crm/win_loss_reports/trends
      def trends
        period = params[:period] || 'month' # day, week, month, quarter
        limit = params[:limit]&.to_i || 12
        
        date_format = case period
        when 'day'
          '%Y-%m-%d'
        when 'week'
          '%Y-%U'
        when 'quarter'
          '%Y-Q%q'
        else
          '%Y-%m'
        end
        
        reports = WinLossReport.where('created_at >= ?', limit.send(period.pluralize).ago)
        
        trends_data = reports.group("strftime('#{date_format}', created_at)")
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
        report.user_id = current_user_id
        
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

      def set_deal
        @deal = Deal.find(params[:deal_id])
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

      def current_user_id
        # This should be set by your authentication system
        current_user&.id
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
