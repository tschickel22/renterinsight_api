module Api
  module V1
    class ReportAiController < ApplicationController
      before_action :set_company_scope
      before_action :check_ai_enabled

      # POST /api/v1/report-ai/ask
      def ask
        return unless authorize_action!('reports', 'read')

        question = params[:question]&.strip
        if question.blank?
          return render json: { error: 'Question is required' }, status: :unprocessable_entity
        end

        # Reject non-business questions before spending tokens.
        unless business_relevant?(question)
          return render json: {
            explanation: "I can only help with questions about your dealership data — leads, deals, invoices, service tickets, homes, and payments. Try asking something like 'Show me deals closed this week'.",
            query: nil,
            data: nil,
            usage: ai_report_usage
          }
        end

        usage = ai_report_usage
        if usage[:remaining] <= 0
          AiQueryLog.create!(
            company_id: @company.id,
            user_id: current_user&.id,
            location_id: Current.location_id,
            feature: 'report_ai',
            question: question,
            execution_status: 'rate_limited'
          )
          return render json: {
            error: "Monthly AI query limit reached (#{usage[:limit]} queries). Resets #{usage[:resets_at]}.",
            usage: usage
          }, status: :too_many_requests
        end

        api_key = ENV['ANTHROPIC_API_KEY'] || Rails.application.credentials.dig(:anthropic, :api_key)
        unless api_key.present?
          return render json: { error: 'AI features are not configured.' }, status: :service_unavailable
        end

        field_defs = {}
        ReportEngine.available_modules.each do |key, _klass|
          field_defs[key] = ReportEngine.field_definitions(key, @company.id)
        end

        log = nil
        started_at = Time.current

        begin
          service = ReportAiService.new(api_key)
          result = service.translate(question, field_defs, {
            today: Date.current.to_s,
            company_name: @company.name
          })

          query_params = result[:query_params]

          unless query_params&.dig(:module).present?
            log = AiQueryLog.create!(
              company_id: @company.id,
              user_id: current_user&.id,
              location_id: Current.location_id,
              feature: 'report_ai',
              question: question,
              execution_status: 'error',
              input_tokens: result[:input_tokens],
              output_tokens: result[:output_tokens],
              cost_cents: result[:cost_cents],
              response_time_ms: result[:response_time_ms],
              error_message: result[:explanation]
            )

            return render json: {
              explanation: result[:explanation],
              query: nil,
              data: nil,
              usage: ai_report_usage
            }
          end

          # all_locations: true bypasses location filter (used by digest tile click-throughs)
          # so company-wide digest counts match company-wide query results
          effective_location_id = params[:all_locations] == 'true' ? nil : Current.location_id

          report_data = ReportEngine.run(
            query_params.merge(
              company_id: @company.id,
              location_id: effective_location_id
            )
          )

          status = report_data[:rows].any? ? 'success' : 'no_results'

          log = AiQueryLog.create!(
            company_id: @company.id,
            user_id: current_user&.id,
            location_id: Current.location_id,
            feature: 'report_ai',
            question: question,
            user_question: question,
            resolved_intent: 'read',
            action_name: query_params[:module],
            module_key: query_params[:module],
            generated_params: query_params,
            execution_status: status,
            failure_reason: status == 'no_results' ? 'no_results' : nil,
            result_count: report_data[:rows].count,
            input_tokens: result[:input_tokens],
            output_tokens: result[:output_tokens],
            cost_cents: result[:cost_cents],
            response_time_ms: result[:response_time_ms]
          )

          summary = service.summarize_results(question, report_data) rescue nil

          render json: {
            explanation: result[:explanation],
            summary: summary,
            query: query_params,
            data: report_data,
            usage: ai_report_usage,
            query_id: log.id
          }

        rescue ReportAiService::AiError => e
          AiQueryLog.create!(
            company_id: @company.id,
            user_id: current_user&.id,
            location_id: Current.location_id,
            feature: 'report_ai',
            question: question,
            execution_status: 'error',
            error_message: e.message,
            response_time_ms: ((Time.current - started_at) * 1000).to_i
          )
          render json: { error: e.message }, status: :unprocessable_entity
        rescue => e
          Rails.logger.error "[ReportAI] Unexpected error: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
          render json: { error: 'AI query failed unexpectedly. Please try again.' }, status: :internal_server_error
        end
      end

      # GET /api/v1/report-ai/usage
      def usage
        return unless authorize_action!('reports', 'read')
        render json: { usage: ai_report_usage }
      end

      # GET /api/v1/report-ai/suggested
      def suggested
        return unless authorize_action!('reports', 'read')

        # Only surface popular questions that actually returned data (result_count > 0)
        # This prevents questions about features with no data from appearing
        popular = AiQueryLog.where(company_id: @company.id, feature: 'report_ai', execution_status: 'success')
          .where('result_count > 0')
          .where.not(question: [nil, ''])
          .group(:question, :module_key)
          .order('count_all DESC')
          .limit(5)
          .count
          .map { |(q, mod), count| { question: q, module_key: mod, count: count } }

        render json: {
          popular: popular,
          suggested: SUGGESTED_QUESTIONS
        }
      end

      # GET /api/v1/report-ai/history
      def history
        return unless authorize_action!('reports', 'read')
        return render json: { error: 'Admin access required' }, status: :forbidden unless current_user&.effective_admin?

        logs = AiQueryLog
          .where(company_id: @company.id, feature: 'report_ai')
          .order(created_at: :desc)
          .limit(100)
          .includes(:user)

        render json: {
          items: logs.map { |log|
            {
              id: log.id,
              question: log.question,
              module_key: log.module_key,
              execution_status: log.execution_status,
              result_count: log.result_count,
              input_tokens: log.input_tokens,
              output_tokens: log.output_tokens,
              cost_cents: log.cost_cents,
              asked_by: log.user ? "#{log.user.first_name} #{log.user.last_name}".strip.presence || log.user.email : 'Unknown',
              created_at: log.created_at
            }
          }
        }
      end

      # GET /api/v1/report-ai/platform-insights
      def platform_insights
        unless current_user&.role == 'platform_admin'
          return render json: { error: 'Platform admin access required' }, status: :forbidden
        end

        render json: {
          popular_questions: AiQueryLog.platform_popular_questions(limit: 50),
          monthly_stats: AiQueryLog
            .where(feature: 'report_ai')
            .where('created_at >= ?', 6.months.ago)
            .group("DATE_TRUNC('month', created_at)", :execution_status)
            .count
            .map { |(month, status), count| { month: month, status: status, count: count } },
          total_queries: AiQueryLog.where(feature: 'report_ai').count,
          total_cost_dollars: AiQueryLog.where(feature: 'report_ai').sum(:cost_cents).to_f / 100
        }
      end

      # POST /api/v1/report-ai/classify
      def classify
        return unless authorize_action!('reports', 'read')

        question = params[:question]&.strip
        return render json: { error: 'Question is required' }, status: :unprocessable_entity if question.blank?

        usage = ai_report_usage
        if usage[:remaining] <= 0
          return render json: {
            error: "Monthly AI query limit reached. Resets #{usage[:resets_at]}.",
            usage: usage
          }, status: :too_many_requests
        end

        api_key = ENV['ANTHROPIC_API_KEY'] || Rails.application.credentials.dig(:anthropic, :api_key)
        return render json: { error: 'AI not configured' }, status: :service_unavailable unless api_key.present?

        sources = @company.sources.order(:name).map { |s| { id: s.id, name: s.name } } rescue []
        users   = @company.users.where(is_active: true).order(:first_name).map { |u|
          { id: u.id, name: "#{u.first_name} #{u.last_name}".strip }
        } rescue []

        service = AiActionService.new(api_key)
        # If the frontend passes entity_type/entity_id (current page context),
        # inject them into classification context so Claude defaults to the right entity.
        page_entity_type = params[:entity_type]&.downcase
        page_entity_id   = params[:entity_id]&.to_i

        result  = service.classify(question, {
          today: Date.current.to_s,
          company_name: @company.name,
          current_user_name: "#{current_user&.first_name} #{current_user&.last_name}".strip,
          sources: sources,
          users: users,
          location_id: Current.location_id,
          page_entity_type: page_entity_type,
          page_entity_id:   page_entity_id
        })

        AiQueryLog.create!(
          company_id:       @company.id,
          user_id:          current_user&.id,
          location_id:      Current.location_id,
          feature:          'report_ai',
          question:         question,
          user_question:    question,
          resolved_intent:  result[:intent],
          action_name:      result[:action],
          module_key:       result[:action],
          generated_params: result[:params],
          execution_status: result[:intent] == 'unknown' ? 'no_match' : 'classified',
          failure_reason:   result[:intent] == 'unknown' ? 'unknown_intent' : nil,
          input_tokens:     result[:input_tokens],
          output_tokens:    result[:output_tokens],
          cost_cents:       result[:cost_cents],
          response_time_ms: result[:response_time_ms]
        )

        render json: {
          intent:                result[:intent],
          action:                result[:action],
          requires_confirmation: result[:requires_confirmation],
          explanation:           result[:explanation],
          params:                result[:params],
          usage:                 ai_report_usage
        }

      rescue AiActionService::AiError => e
        render json: { error: e.message }, status: :unprocessable_entity
      rescue => e
        Rails.logger.error "[ReportAI#classify] #{e.message}"
        render json: { error: 'Classification failed' }, status: :internal_server_error
      end

      # POST /api/v1/report-ai/execute
      def execute
        return unless authorize_action!('reports', 'read')

        action      = params[:action_name]
        intent      = params[:intent]
        exec_params = (params[:params] || {}).to_unsafe_h

        return render json: { error: 'action_name is required' }, status: :unprocessable_entity if action.blank?

        api_key = ENV['ANTHROPIC_API_KEY'] || Rails.application.credentials.dig(:anthropic, :api_key)
        return render json: { error: 'AI not configured' }, status: :service_unavailable unless api_key.present?

        if intent == 'draft'
          # For draft_email: resolve the recipient to get their entity ID + view path
          resolved_entity_id   = nil
          resolved_entity_type = exec_params['entity_type']&.downcase || 'lead'
          resolved_view_path   = nil

          if action == 'draft_email' && exec_params['recipient_name'].present? && exec_params['entity_id'].blank?
            name = exec_params['recipient_name'].to_s
            parts = name.split(' ', 2)
            entity = case resolved_entity_type
            when 'contact'
              @company.contacts.where("first_name ILIKE ? AND last_name ILIKE ?", parts[0], parts[1] || '%').first ||
              @company.contacts.where("first_name ILIKE ? OR last_name ILIKE ?", "%#{name}%", "%#{name}%").first
            when 'account'
              @company.accounts.where("name ILIKE ?", "%#{name}%").first
            when 'deal'
              @company.deals.where("deal_number ILIKE ? OR name ILIKE ?", "%#{name}%", "%#{name}%").first
            else
              @company.leads.where("first_name ILIKE ? AND last_name ILIKE ?", parts[0], parts[1] || '%').first ||
              @company.leads.where("first_name ILIKE ? OR last_name ILIKE ?", "%#{name}%", "%#{name}%").first
            end
            if entity
              resolved_entity_id = entity.id
              path_base = case resolved_entity_type
              when 'contact' then "/contacts/#{entity.id}"
              when 'account' then "/accounts/#{entity.id}"
              when 'deal'    then "/deals/#{entity.id}"
              else "/crm/leads/#{entity.id}"
              end
              resolved_view_path = "#{path_base}?tab=communication"
            end
          end

          if action == 'summarize_record' && exec_params['entity_identifier'].present?
            record_data = load_record_for_summary(exec_params['entity_type'], exec_params['entity_identifier'])
            exec_params['_record_data'] = record_data
          end

          service = AiDraftService.new(api_key)
          result  = service.generate(action, exec_params, {
            company_name: @company.name,
            record_data: exec_params['_record_data']
          })

          AiQueryLog.create!(
            company_id: @company.id, user_id: current_user&.id, location_id: Current.location_id,
            feature: 'report_ai', module_key: action, execution_status: 'success',
            input_tokens: result[:input_tokens], output_tokens: result[:output_tokens], cost_cents: result[:cost_cents]
          )

          render json: {
            intent:      'draft',
            action:      action,
            content:     result[:content],
            entity_id:   resolved_entity_id,
            entity_type: resolved_entity_type,
            view_path:   resolved_view_path,
            usage:       ai_report_usage
          }

        else
          executor = AiActionExecutor.new(@company, current_user, Current.location_id)
          result   = executor.execute(action, exec_params)

          failure_reason = if result[:success]
            nil
          elsif result[:disambiguate]
            'disambiguation'
          elsif result[:message].to_s.include?('Could not find')
            'entity_not_found'
          elsif result[:message].to_s.include?('not yet supported')
            'unsupported_action'
          else
            'validation_error'
          end

          AiQueryLog.create!(
            company_id: @company.id, user_id: current_user&.id, location_id: Current.location_id,
            feature: 'report_ai', module_key: action,
            user_question: params[:question].presence || exec_params['entity_name'],
            action_name: action,
            resolved_intent: 'write',
            entity_name_searched: exec_params['entity_name'],
            entity_type_attempted: exec_params['entity_type'],
            disambiguate_count: (result[:matches]&.size if result[:disambiguate]),
            error_message: (result[:message] if result[:success] == false),
            failure_reason: failure_reason,
            execution_status: result[:success] ? 'success' : (result[:disambiguate] ? 'disambiguation' : 'error'),
            result_count: result[:success] ? 1 : 0
          )

          render json: {
            intent:         'write',
            action:         action,
            success:        result[:success],
            message:        result[:message],
            record:         result[:record],
            record_id:      result[:record_id],
            view_path:      result[:view_path],
            data:           result[:data],
            disambiguate:   result[:disambiguate],
            matches:        result[:matches],
            pending_action: result[:pending_action],
            pending_params: result[:pending_params],
            entity_type:    result[:entity_type],
            usage:          ai_report_usage
          }
        end

      rescue AiActionExecutor::ExecutionError => e
        render json: { success: false, error: e.message }, status: :unprocessable_entity
      rescue AiDraftService::AiError => e
        render json: { error: e.message }, status: :unprocessable_entity
      rescue => e
        Rails.logger.error "[ReportAI#execute] #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
        render json: { error: e.message }, status: :internal_server_error
      end

      # POST /api/v1/report-ai/contextual
      def contextual
        return unless authorize_action!('reports', 'read')

        question     = params[:question]&.strip
        context_type = params[:context_type]
        context_id   = params[:context_id]

        return render json: { error: 'Question required' }, status: :unprocessable_entity if question.blank?

        usage = ai_report_usage
        if usage[:remaining] <= 0
          return render json: { error: "Monthly limit reached. Resets #{usage[:resets_at]}.", usage: usage },
                        status: :too_many_requests
        end

        api_key = ENV['ANTHROPIC_API_KEY'] || Rails.application.credentials.dig(:anthropic, :api_key)
        return render json: { error: 'AI not configured' }, status: :service_unavailable unless api_key.present?

        context_record = load_context_record(context_type, context_id)

        sources = @company.sources.order(:name).map { |s| { id: s.id, name: s.name } } rescue []
        users   = @company.users.where(is_active: true).order(:first_name).map { |u|
          { id: u.id, name: "#{u.first_name} #{u.last_name}".strip }
        } rescue []

        enriched_question = context_record.present? ?
          "#{question} [Context: #{context_type} record — #{context_record.to_json}]" :
          question

        service = AiActionService.new(api_key)
        result  = service.classify(enriched_question, {
          today: Date.current.to_s,
          company_name: @company.name,
          current_user_name: "#{current_user&.first_name} #{current_user&.last_name}".strip,
          sources: sources, users: users, location_id: Current.location_id
        })

        if context_id.present? && result[:params].present?
          case context_type
          when 'lead' then result[:params]['lead_id'] ||= context_id.to_i
          when 'deal' then result[:params]['deal_id'] ||= context_id.to_i
          end
        end

        AiQueryLog.create!(
          company_id: @company.id, user_id: current_user&.id, location_id: Current.location_id,
          feature: 'report_ai', question: question, module_key: "contextual_#{context_type}",
          execution_status: 'success', input_tokens: result[:input_tokens],
          output_tokens: result[:output_tokens], cost_cents: result[:cost_cents]
        )

        render json: {
          intent:                result[:intent],
          action:                result[:action],
          requires_confirmation: result[:requires_confirmation],
          explanation:           result[:explanation],
          params:                result[:params],
          context_record:        context_record,
          usage:                 ai_report_usage
        }

      rescue => e
        Rails.logger.error "[ReportAI#contextual] #{e.message}"
        render json: { error: 'Contextual AI failed' }, status: :internal_server_error
      end

      # GET /api/v1/report-ai/failure-log
      def failure_log
        return unless authorize_action!('reports', 'read')

        logs = AiQueryLog.where(company_id: @company.id, feature: 'report_ai')
        logs = logs.where.not(execution_status: ['success', 'classified'])
        logs = logs.where(failure_reason: params[:failure_reason]) if params[:failure_reason].present?
        logs = logs.where('created_at >= ?', params[:from].to_date) if params[:from].present?
        logs = logs.order(created_at: :desc).limit(200)

        stats = {
          total_failures: AiQueryLog.where(company_id: @company.id, feature: 'report_ai')
                                    .where.not(execution_status: ['success', 'classified'])
                                    .where('created_at >= ?', 30.days.ago).count,
          by_reason: AiQueryLog.where(company_id: @company.id, feature: 'report_ai')
                                .where.not(failure_reason: nil)
                                .where('created_at >= ?', 30.days.ago)
                                .group(:failure_reason).count,
          by_action: AiQueryLog.where(company_id: @company.id, feature: 'report_ai')
                                .where(execution_status: 'error')
                                .where('created_at >= ?', 30.days.ago)
                                .group(:action_name).count
        }

        render json: {
          logs: logs.map { |l|
            {
              id: l.id,
              created_at: l.created_at,
              user_question: l.user_question,
              action_name: l.action_name,
              resolved_intent: l.resolved_intent,
              execution_status: l.execution_status,
              failure_reason: l.failure_reason,
              entity_name_searched: l.entity_name_searched,
              entity_type_attempted: l.entity_type_attempted,
              error_message: l.error_message,
              disambiguate_count: l.disambiguate_count,
              result_count: l.result_count
            }
          },
          stats: stats
        }
      end

      # POST /api/v1/report-ai/trigger-digest  (platform admin only)
      def trigger_digest
        unless current_user&.role == 'platform_admin'
          return render json: { error: 'Platform admin required' }, status: :forbidden
        end

        company_id = params[:company_id] || @company.id
        SendAiDigestJob.perform_later(company_id: company_id.to_i)
        render json: { message: "Digest queued for company #{company_id}" }
      end

      # POST /api/v1/report-ai/refresh-digest  (any company admin)
      # Lets admins pull a fresh digest on demand rather than waiting for Monday
      def refresh_digest
        unless current_user&.effective_admin?
          return render json: { error: 'Admin access required' }, status: :forbidden
        end

        api_key = ENV['ANTHROPIC_API_KEY'] || Rails.application.credentials.dig(:anthropic, :api_key)
        return render json: { error: 'AI not configured' }, status: :service_unavailable unless api_key.present?

        usage = ai_report_usage
        return render json: { error: 'AI query limit reached' }, status: :too_many_requests if usage[:remaining] <= 0

        # Run synchronously so the user gets the result immediately
        service = AiDigestService.new(api_key)
        result  = service.generate_for_company(@company)

        # Persist to sessionStorage via the response — frontend stores it
        render json: {
          summary: result[:summary],
          stats:   result[:stats],
          week:    result[:stats][:week]
        }

      rescue AiDigestService::DigestError => e
        render json: { error: e.message }, status: :unprocessable_entity
      rescue => e
        Rails.logger.error "[RefreshDigest] #{e.message}"
        render json: { error: 'Digest generation failed' }, status: :internal_server_error
      end

      # GET /api/v1/report-ai/digest-drilldown?stat=new_leads
      # Runs the EXACT same queries as AiDigestService so tile click-throughs
      # always match the digest counts. No Claude involved.
      def digest_drilldown
        return unless authorize_action!('reports', 'read')

        stat = params[:stat]
        now        = Time.current
        week_start = now.beginning_of_week

        case stat
        when 'new_leads'
          records = @company.leads
            .where(created_at: week_start..now)
            .includes(:source, :owner)
            .order(created_at: :desc)
            .limit(100)

          rows = records.map do |l|
            {
              id: l.id,
              name: "#{l.first_name} #{l.last_name}".strip,
              email: l.email,
              phone: l.phone,
              status: l.status,
              source: l.source&.name,
              created_at: l.created_at&.strftime('%Y-%m-%d')
            }
          end

          columns = [
            { key: 'name',       label: 'Name' },
            { key: 'email',      label: 'Email' },
            { key: 'phone',      label: 'Phone' },
            { key: 'status',     label: 'Status' },
            { key: 'source',     label: 'Source' },
            { key: 'created_at', label: 'Created' },
          ]
          explanation = "Leads created this week (#{week_start.strftime('%b %d')} – #{now.strftime('%b %d')}), company-wide."

        when 'deals_closed'
          records = @company.deals
            .where(stage: 'closed_won')
            .where('won_at >= ? OR updated_at >= ?', week_start, week_start)
            .order(Arel.sql('COALESCE(won_at, updated_at) DESC'))
            .limit(100)

          rows = records.map do |d|
            {
              id: d.id,
              deal_number: d.try(:deal_number) || "##{d.id}",
              name: d.try(:name) || d.try(:title) || "Deal ##{d.id}",
              value: d.try(:value) || d.try(:selling_price),
              stage: d.stage,
              closed_at: (d.try(:won_at) || d.updated_at)&.strftime('%Y-%m-%d')
            }
          end

          columns = [
            { key: 'deal_number', label: 'Deal #' },
            { key: 'name',        label: 'Name' },
            { key: 'value',       label: 'Value' },
            { key: 'stage',       label: 'Stage' },
            { key: 'closed_at',   label: 'Closed' },
          ]
          explanation = "Deals marked closed-won this week (#{week_start.strftime('%b %d')} – #{now.strftime('%b %d')}), company-wide."

        when 'overdue_tickets'
          records = @company.service_tickets
            .where(status: %w[open in_progress pending_review])
            .where('scheduled_date < ?', Date.current)
            .order(scheduled_date: :asc)
            .limit(100)

          rows = records.map do |t|
            {
              id: t.id,
              ticket_number: t.try(:ticket_number) || "##{t.id}",
              title: t.title,
              status: t.status,
              priority: t.try(:priority),
              scheduled_date: t.try(:scheduled_date)&.strftime('%Y-%m-%d'),
              days_overdue: t.try(:scheduled_date) ? (Date.current - t.scheduled_date).to_i : nil
            }
          end

          columns = [
            { key: 'ticket_number',  label: 'Ticket #' },
            { key: 'title',          label: 'Title' },
            { key: 'status',         label: 'Status' },
            { key: 'priority',       label: 'Priority' },
            { key: 'scheduled_date', label: 'Due Date' },
            { key: 'days_overdue',   label: 'Days Overdue' },
          ]
          explanation = "Open/in-progress service tickets with a scheduled date before today, company-wide."

        else
          return render json: { error: "Unknown stat: #{stat}" }, status: :bad_request
        end

        render json: {
          stat: stat,
          explanation: explanation,
          data: {
            rows: rows,
            columns: columns,
            meta: { total: rows.size }
          }
        }

      rescue => e
        Rails.logger.error "[DigestDrilldown] #{e.message}"
        render json: { error: 'Drilldown failed' }, status: :internal_server_error
      end

      def load_context_record(context_type, context_id)
        return nil unless context_type.present? && context_id.present?
        case context_type
        when 'lead'
          lead = @company.leads.find_by(id: context_id)
          lead ? { id: lead.id, name: lead.full_name, phone: lead.phone, email: lead.email,
                   status: lead.status, created_at: lead.created_at } : nil
        when 'deal'
          deal = @company.deals.find_by(id: context_id)
          deal ? { id: deal.id, deal_number: deal.deal_number, name: deal.name,
                   stage: deal.stage, value: deal.value } : nil
        when 'service_ticket'
          ticket = @company.service_tickets.find_by(id: context_id)
          ticket ? { id: ticket.id, ticket_number: ticket.ticket_number,
                     title: ticket.title, status: ticket.status, priority: ticket.priority } : nil
        when 'contact'
          contact = @company.contacts.find_by(id: context_id)
          contact ? { id: contact.id, name: "#{contact.first_name} #{contact.last_name}".strip,
                      email: contact.email, phone: contact.phone } : nil
        end
      rescue
        nil
      end

      def load_record_for_summary(entity_type, identifier)
        case entity_type
        when 'deal'
          deal = @company.deals.find_by(deal_number: identifier) || @company.deals.find_by(id: identifier.to_i)
          deal&.as_json(only: [:id, :name, :stage, :value, :selling_price, :created_at, :expected_close_date])
        when 'lead'
          lead = @company.leads.find_by(id: identifier.to_i)
          lead&.as_json(only: [:id, :first_name, :last_name, :email, :phone, :status, :created_at])
        end
      rescue
        nil
      end

      def ai_report_usage
        used = AiQueryLog
          .where(company_id: @company.id, feature: 'report_ai')
          .where.not(execution_status: 'rate_limited')
          .where('created_at >= ?', Time.current.beginning_of_month)
          .count

        limit = get_ai_report_limit

        {
          used: used,
          limit: limit,
          remaining: [limit - used, 0].max,
          resets_at: Time.current.end_of_month.strftime('%B %d, %Y'),
          month: Time.current.strftime('%B %Y'),
          enabled: limit > 0
        }
      end

      def get_ai_report_limit
        return 999 if current_user&.role == 'platform_admin'

        # Check if the company has the AI module enabled via subscription
        company_has_module = begin
          @company.platform_modules.to_a.include?('management_ai_reports')
        rescue
          false
        end

        company_limit = begin
          Setting.get('Company', @company.id, 'ai_report_queries_monthly_limit', nil)
        rescue => e
          Rails.logger.debug "[ReportAI] Could not read company limit setting: #{e.message}"
          nil
        end
        return company_limit.to_i if company_limit.present? && company_limit.to_i > 0

        platform_limit = begin
          Setting.get('Platform', 0, 'ai_report_queries_monthly_limit', nil)
        rescue => e
          Rails.logger.debug "[ReportAI] Could not read platform limit setting: #{e.message}"
          nil
        end
        return platform_limit.to_i if platform_limit.present? && platform_limit.to_i > 0

        # Module is subscribed but no limit configured yet — default to 100
        return 100 if company_has_module

        0
      end

      def check_ai_enabled
        usage = ai_report_usage
        unless usage[:enabled]
          render json: {
            error: 'AI reporting is not enabled for your account. Contact support to enable this feature.',
            enabled: false
          }, status: :forbidden
        end
      end

      # Returns true if the question is plausibly about dealership business data.
      # Cheap keyword check — runs before Claude to avoid wasting tokens on off-topic queries.
      BUSINESS_KEYWORDS = %w[
        lead leads contact contacts deal deals account accounts
        invoice invoices payment payments service ticket tickets
        home homes vehicle vehicles inventory parts warranty
        sales revenue commission staff rep salesperson
        close closed won lost stage pipeline
        follow followup overdue unpaid pending open
        show list find who which how many what when
        today week month year this last past
      ].freeze

      def business_relevant?(question)
        q = question.to_s.downcase
        # Must contain at least one business keyword
        BUSINESS_KEYWORDS.any? { |kw| q.include?(kw) }
      end

      SUGGESTED_QUESTIONS = [
        { category: 'sales', module_key: 'deals',    icon: 'trophy',      question: 'Who is my top sales rep this month?' },
        { category: 'sales', module_key: 'deals',    icon: 'calendar',    question: 'Show me deals closed in the past 7 days' },
        { category: 'sales', module_key: 'deals',    icon: 'clock',       question: 'Which deals are closing this month?' },
        { category: 'sales', module_key: 'leads',    icon: 'user-x',      question: "Which leads haven't been contacted in 2 weeks?" },
        { category: 'sales', module_key: 'leads',    icon: 'trending-up', question: 'Show me new leads from this week' },
        { category: 'sales', module_key: 'deals',    icon: 'dollar-sign', question: 'What is my average deal value?' },
        { category: 'finance', module_key: 'invoices', icon: 'alert-circle', question: 'Show me unpaid invoices over 30 days' },
        { category: 'finance', module_key: 'invoices', icon: 'bar-chart',    question: 'Revenue by month this year' },
        { category: 'finance', module_key: 'payments', icon: 'check-circle', question: 'Payments received this week' },
        { category: 'operations', module_key: 'service_tickets', icon: 'alert-triangle', question: 'Show me all overdue service tickets' },
        { category: 'operations', module_key: 'service_tickets', icon: 'wrench',         question: 'Open high priority service tickets' },
        { category: 'inventory',  module_key: 'vehicles',        icon: 'home',           question: 'Homes available in stock' },
        { category: 'inventory',  module_key: 'vehicles',        icon: 'tag',            question: 'Show me homes sold this month' },
      ].freeze
    end
  end
end
