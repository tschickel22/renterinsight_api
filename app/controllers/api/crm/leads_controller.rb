module Api
  module Crm
    class LeadsController < ApplicationController
      before_action :set_company_scope
      before_action :set_lead, only: [:show, :update, :destroy, :notes, :convert, :score, :conversion_integrity_check]

      # Legacy default — kept ONLY as a fallback if a company somehow has no
      # lead_statuses rows yet (shouldn't happen post-migration). The real
      # excluded list comes from each tenant's lead_statuses table now, so
      # admins can mark custom statuses as dead-end via the Lead Statuses tab.
      DEFAULT_EXCLUDED_STATUSES = %w[
        closed_lost lost_lead not_qualified junk_lead
      ].freeze

      def index
        return unless authorize_action!('leads', 'read')

        leads = base_leads_scope

        # Count stats BEFORE any filtering (stats tiles show global counts)
        all_leads_count = leads.count
        excluded = excluded_status_keys
        active_count = leads.where.not(status: excluded).count
        inactive_count = leads.where(status: excluded).count
        # by_status: every status actually present in this tenant's data, with counts.
        # Lets the frontend build the status filter dropdown from real data instead of
        # a hardcoded enum (which misses imported/legacy statuses and shows zero-count
        # options that no lead actually has).
        by_status = leads.where.not(status: nil).group(:status).count
        status_counts = {
          total: all_leads_count,
          active: active_count,
          inactive: inactive_count,
          new: by_status['new'] || 0,
          qualified: by_status['qualified'] || 0,
          contacted: by_status['contacted'] || 0,
          proposal: by_status['proposal'] || 0,
          engaged: by_status['engaged'] || 0,
          showing_scheduled: by_status['showing_scheduled'] || 0,
          application_submitted: by_status['application_submitted'] || 0,
          by_status: by_status,
        }
        
        # Calculate percentage changes
        last_month_start = 1.month.ago.beginning_of_month
        last_month_end = 1.month.ago.end_of_month
        last_month_total = leads.where(created_at: last_month_start..last_month_end).count
        total_change_pct = calculate_percentage_change(last_month_total, all_leads_count)
        
        last_week_start = 1.week.ago.beginning_of_week
        last_week_end = 1.week.ago.end_of_week
        this_week_new = leads.where(status: 'new', created_at: Time.current.beginning_of_week..Time.current).count
        last_week_new = leads.where(status: 'new', created_at: last_week_start..last_week_end).count
        new_change_pct = calculate_percentage_change(last_week_new, this_week_new)
        
        this_month_qualified = leads.where(status: 'qualified', created_at: Time.current.beginning_of_month..Time.current).count
        last_month_qualified = leads.where(status: 'qualified', created_at: last_month_start..last_month_end).count
        qualified_change_pct = calculate_percentage_change(last_month_qualified, this_month_qualified)
        
        contacted_subtitle = 'In progress'
        
        # Server-side filters: status_category, search, owner_id. owner_id was added so a
        # "bulk reassign all matching" action (e.g. when a rep quits) can target the full
        # filtered set, not just the current page — see bulk_reassign below.
        leads = apply_index_filters(leads, params)

        # Count AFTER filters (for pagination)
        filtered_count = leads.count
        
        leads = leads.includes(:source, :owner, :vehicle, :lead_scores, :tags)
        leads = apply_index_sort(leads, params[:sort], params[:order])
        
        # Pagination
        page = (params[:page] || 1).to_i
        per_page = (params[:per_page] || 50).to_i
        per_page = [per_page, 200].min # Max 200 per page
        
        leads = leads.offset((page - 1) * per_page).limit(per_page)
        
        render json: {
          leads: leads.map { |l| lead_json(l) },
          meta: {
            total: filtered_count,  # For pagination (filtered results)
            page: page,
            per_page: per_page,
            total_pages: (filtered_count.to_f / per_page).ceil,
            stats: status_counts.merge(
              changes: {
                total: total_change_pct,
                new: new_change_pct,
                qualified: qualified_change_pct,
                contacted: contacted_subtitle
              }
            )  # For tiles (unfiltered totals with percentage changes)
          }
        }
      end

      # GET /api/crm/leads/kanban
      # Returns leads grouped by status for the Kanban view. Each column is
      # capped at per_column (default 50) cards sorted by last_activity_at desc
      # so a tenant with 9k leads doesn't render every card. The total count
      # per column reflects the FULL filtered set (used by the column header
      # and the "load more" link).
      def kanban
        return unless authorize_action!('leads', 'read')

        leads = apply_index_filters(base_leads_scope, params)
        per_column = (params[:per_column].presence || 50).to_i.clamp(1, 200)

        # Statuses to render = tenant's configured + any in-use status not in
        # the configured list (defensive: don't drop a column if data drifts).
        configured_keys = @company.lead_statuses.active.ordered.pluck(:key)
        in_use_keys = leads.where.not(status: nil).distinct.pluck(:status)
        status_keys = (configured_keys + in_use_keys).uniq

        columns = status_keys.each_with_object({}) do |status_key, acc|
          scope = leads.where(status: status_key)
          total = scope.count
          # Skip empty columns unless the admin explicitly configured this
          # status (we still want to show those so users can drop cards in).
          next if total.zero? && !configured_keys.include?(status_key)

          card_leads = scope.includes(:source, :owner, :vehicle, :lead_scores, :tags)
                            .order(Arel.sql('last_activity_at DESC NULLS LAST'))
                            .limit(per_column)
                            .to_a

          # Batch the open-task count per lead so the kanban card can show a
          # "has tasks" indicator. One GROUP BY for all cards in this column
          # vs N+1 queries through lead_json.
          task_counts = if card_leads.any?
            Activity.where(
              lead_id: card_leads.map(&:id),
              activity_type: 'lead_activity_task',
              completed_date: nil
            ).group(:lead_id).count
          else
            {}
          end

          cards = card_leads.map do |l|
            lead_json(l).merge(openTaskCount: task_counts[l.id] || 0)
          end

          acc[status_key] = { leads: cards, total: total }
        end

        render json: { columns: columns, per_column: per_column }
      end

      def show
        return unless authorize_action!('leads', 'read')
        
        render json: lead_json(@lead)
      end

      def create
        return unless authorize_action!('leads', 'create')

        Rails.logger.info "[LeadsController#create] Received params: #{params.inspect}"
        Rails.logger.info "[LeadsController#create] Processed lead_params: #{lead_params.inspect}"

        # Validate custom field values before creating
        custom_errors = validate_custom_field_values('leads', custom_field_values_param)
        if custom_errors.any?
          render json: { error: 'Validation failed', details: custom_errors }, status: :unprocessable_entity
          return
        end

        # HARD BLOCK on duplicate email (create only). Phone duplicates are a
        # soft warning surfaced by the frontend and are NOT blocked here.
        # The frontend also blocks before submit, but enforce server-side too
        # since the form check can be bypassed.
        dup_email = lead_params[:email].to_s.strip.downcase
        if dup_email.present?
          existing = @company.leads
                             .where(is_converted: [false, nil])
                             .where('LOWER(email) = ?', dup_email)
                             .first
          if existing
            render json: {
              error: 'A lead with this email already exists.',
              duplicate: {
                field: 'email',
                id: existing.id,
                firstName: existing.first_name,
                lastName: existing.last_name,
                email: existing.email,
                phone: existing.phone,
                status: existing.status
              }
            }, status: :conflict
            return
          end
        end

        # STRICT TENANT ISOLATION: Create lead within current company
        l = @company.leads.new(lead_params)
        l.custom_field_values = custom_field_values_param if custom_field_values_param.present?

        # Auto-assign owner to current user if not specified
        l.owner_id ||= current_user&.id

        # Auto-assign location from selector (if user selected a specific location)
        l.location_id ||= Current.location_id if Current.location_id.present?

        # RBAC fallback: Location-tier users auto-assign to their first location if no selector
        if l.location_id.nil? && current_user.uses_rbac? && !current_user.effective_admin?
          location_ids = permission_service.accessible_location_ids
          l.location_id ||= location_ids.first if location_ids.any?
        end

        # Validate only required fields that are visible in active layout
        layout_errors = validate_visible_required_fields('leads', l)
        if layout_errors.any?
          Rails.logger.error "[LeadsController#create] Layout validation failed: #{layout_errors.join(', ')}"
          render json: {
            error: 'Validation failed',
            details: layout_errors
          }, status: :unprocessable_entity
          return
        end

        if l.save(validate: false)  # Skip model validations, we validated above
          Rails.logger.info "[LeadsController#create] Lead created successfully: ID=#{l.id}"
          render json: lead_json(l), status: :created
        else
          Rails.logger.error "[LeadsController#create] Validation failed: #{l.errors.full_messages.join(', ')}"
          render json: {
            error: 'Validation failed',
            details: l.errors.full_messages,
            params_received: lead_params
          }, status: :unprocessable_entity
        end
      rescue => e
        Rails.logger.error "[LeadsController#create] Exception: #{e.class.name}: #{e.message}"
        Rails.logger.error e.backtrace.first(5).join("\n")

        begin
          params_info = lead_params
        rescue
          params_info = 'Could not parse params'
        end

        render json: {
          error: 'Internal server error',
          message: e.message,
          params_received: params_info
        }, status: :internal_server_error
      end

      def update
        return unless authorize_action!('leads', 'update')

        Rails.logger.info "[LeadUpdate] BEFORE: lead_id=#{@lead.id}, owner_id=#{@lead.owner_id}, location_id=#{@lead.location_id}, is_converted=#{@lead.is_converted}"
        Rails.logger.info "[LeadUpdate] PARAMS: #{lead_params.inspect}"
        Rails.logger.info "[LeadUpdate] User: #{current_user.email}, RBAC locations: #{permission_service.accessible_location_ids.inspect}"

        # Validate custom field values before updating (partial: true — only validate submitted fields)
        custom_errors = validate_custom_field_values('leads', custom_field_values_param, partial: true)
        if custom_errors.any?
          render json: { error: 'Validation failed', details: custom_errors }, status: :unprocessable_entity
          return
        end

        update_attrs = lead_params
        if custom_field_values_param.present?
          update_attrs = update_attrs.merge(custom_field_values: (@lead.custom_field_values || {}).merge(custom_field_values_param))
        end

        # Suppress notifications for bulk operations (frontend sends skip_notifications: true)
        @lead.skip_notifications = ActiveModel::Type::Boolean.new.cast(params[:skip_notifications])

        # Apply attributes to lead
        @lead.assign_attributes(update_attrs)

        # Validate only required fields that are visible in active layout AND
        # that were submitted in this update. A status-only PATCH (e.g. Kanban
        # drag-drop) shouldn't fail because of a pre-existing missing email on
        # the lead — we're not touching email in this request.
        layout_errors = validate_visible_required_fields(
          'leads', @lead, submitted_keys: lead_params.keys
        )
        if layout_errors.any?
          Rails.logger.error "[LeadsController#update] Layout validation failed: #{layout_errors.join(', ')}"
          render json: {
            error: 'Validation failed',
            details: layout_errors
          }, status: :unprocessable_entity
          return
        end

        @lead.save!(validate: false)  # Skip model validations, we validated above

        Rails.logger.info "[LeadUpdate] AFTER: lead_id=#{@lead.id}, owner_id=#{@lead.owner_id}, location_id=#{@lead.location_id}, is_converted=#{@lead.is_converted}"

        render json: lead_json(@lead)
      end

      def destroy
        return unless authorize_action!('leads', 'delete')

        @lead.destroy!
        head :no_content
      end

      # POST /api/crm/leads/bulk_reassign
      # Reassigns a set of leads to a new owner in one query — the path that handles
      # "rep quits, move all 500 of their leads to someone else" without the per-row
      # PATCH fan-out the existing bulkUpdateLeads loop does.
      #
      # Accepts EITHER:
      #   lead_ids: [int]         — explicit selection (small batch from the visible page)
      # OR
      #   filter:   { status_category, search, owner_id }
      #                           — "select all matching" mode; backend re-runs the same
      #                             scoping the index used so the user can't extend their
      #                             reach beyond what they can see.
      # PLUS:
      #   assign_to_user_id: int  — new owner (must belong to the same company)
      def bulk_reassign
        return unless authorize_action!('leads', 'update')

        new_owner_id = params[:assign_to_user_id].presence
        return render(json: { error: 'assign_to_user_id required' }, status: :bad_request) if new_owner_id.blank?

        # Owner must belong to the same company — prevents reassigning across tenants.
        new_owner = @company.users.find_by(id: new_owner_id)
        return render(json: { error: 'Invalid assignee' }, status: :unprocessable_entity) unless new_owner

        scope = base_leads_scope

        if params[:filter].present?
          # "Select all matching" path — re-apply the same server-side filters as #index.
          scope = apply_index_filters(scope, params[:filter])
        elsif params[:lead_ids].is_a?(Array) && params[:lead_ids].any?
          # Explicit-selection path — still scoped to base_leads_scope so a user can't
          # reassign a lead they don't have access to by passing its id.
          scope = scope.where(id: params[:lead_ids])
        else
          return render(json: { error: 'lead_ids or filter required' }, status: :bad_request)
        end

        # update_all skips callbacks (notifications, scoring) — exactly what we want for
        # a bulk reassign: a single SQL UPDATE, no 500-row notification storm.
        updated_count = scope.update_all(owner_id: new_owner.id, updated_at: Time.current)

        Rails.logger.info "[LeadsController#bulk_reassign] user=#{current_user.email} reassigned #{updated_count} leads to user_id=#{new_owner.id}"

        render json: { updated_count: updated_count, assigned_to: { id: new_owner.id, name: new_owner.try(:full_name) || new_owner.email } }
      end

      def notes
        return unless authorize_action!('leads', 'update')
        
        @lead.update!(notes: params[:notes].to_s)
        render json: lead_json(@lead)
      end

      def score
        return unless authorize_action!('leads', 'read')
        
        # Calculate lead score based on various factors
        score_value = calculate_lead_score(@lead)
        
        render json: {
          score: score_value,
          factors: [
            { name: 'Email Engagement', value: @lead.email.present? ? 20 : 0 },
            { name: 'Phone Available', value: @lead.phone.present? ? 15 : 0 },
            { name: 'Source Quality', value: @lead.source_id.present? ? 25 : 0 },
            { name: 'Recent Activity', value: 20 },
            { name: 'Profile Completeness', value: 20 }
          ]
        }
      end

      def convert
        return unless authorize_action!('leads', 'update')
        
        begin
          Rails.logger.info "🔄 [ConvertLead] Starting conversion for lead #{params[:id]}"
          Rails.logger.info "🔄 [ConvertLead] Params: account_name=#{params[:account_name]}, create_contact=#{params[:create_contact]}, create_deal=#{params[:create_deal]&.keys}"
          
          # Check if already converted
          if @lead.is_converted
            render json: { error: 'Lead has already been converted' }, status: :unprocessable_entity
            return
          end
          
          ActiveRecord::Base.transaction do
            # Inherit location from lead, fall back to current location selector
            location_id = @lead.location_id || Current.location_id
            # The rep working the lead keeps continuity into the converted records.
            # Falls back to the converter so manager-driven or unowned-lead conversions
            # still produce assigned records.
            inherited_owner_id = @lead.owner_id || current_user&.id

            # 1. FIND OR CREATE ACCOUNT
            # Priority: explicit param > lead.company_name > person name fallback.
            account_name = params[:account_name].presence ||
                           @lead.try(:company_name).presence ||
                           "#{@lead.first_name} #{@lead.last_name}".strip
            account_name = "Converted Lead #{@lead.id}" if account_name.blank?

            Rails.logger.info "✅ [ConvertLead] Finding or creating account: #{account_name}"

            account = Account.find_or_create_by!(name: account_name, company_id: @lead.company_id) do |a|
              a.status = 'active'
              a.email = @lead.email
              a.phone = @lead.phone
              a.source_id = @lead.source_id
              a.notes = @lead.notes
              a.location_id = location_id
              a.owner_id = inherited_owner_id
              a.account_type = 'converted_lead' if a.respond_to?(:account_type=)
              # Copy lead address → account billing address
              a.billing_street      = @lead.street
              a.billing_city        = @lead.city
              a.billing_state       = @lead.state
              a.billing_postal_code = @lead.zip
              a.billing_country     = @lead.country
            end

            Rails.logger.info "✅ [ConvertLead] Account #{account.previously_new_record? ? 'created' : 'reused'}: #{account.id}"

            # 1b. BACKFILL EXISTING ACCOUNT
            # find_or_create_by! only sets email/phone/address on CREATE. When we
            # match a pre-existing account (e.g. an imported one), fill in any
            # contact fields it's missing from the lead — without overwriting data
            # the account already has.
            unless account.previously_new_record?
              backfill = {}
              backfill[:email]               = @lead.email   if account.email.blank?               && @lead.email.present?
              backfill[:phone]               = @lead.phone   if account.phone.blank?               && @lead.phone.present?
              backfill[:billing_street]      = @lead.street  if account.billing_street.blank?      && @lead.street.present?
              backfill[:billing_city]        = @lead.city    if account.billing_city.blank?        && @lead.city.present?
              backfill[:billing_state]       = @lead.state   if account.billing_state.blank?       && @lead.state.present?
              backfill[:billing_postal_code] = @lead.zip     if account.billing_postal_code.blank? && @lead.zip.present?
              backfill[:billing_country]     = @lead.country if account.billing_country.blank?     && @lead.country.present?
              # Only fill the owner when the existing account is unassigned — never steal
              # ownership from a rep who already owns the account.
              backfill[:owner_id]            = inherited_owner_id if account.owner_id.blank? && inherited_owner_id.present?
              if backfill.any?
                account.update!(backfill)
                Rails.logger.info "✅ [ConvertLead] Backfilled existing account #{account.id}: #{backfill.keys.join(', ')}"
              end
            end

            # 2. CREATE CONTACT (if requested or if we have name data)
            contact = nil
            create_contact = params[:create_contact].present? ? 
              ActiveModel::Type::Boolean.new.cast(params[:create_contact]) : 
              (@lead.first_name.present? && @lead.last_name.present?)
            
            if create_contact
              Rails.logger.info "✅ [ConvertLead] Creating contact"
              
              contact_attrs = {
                first_name: @lead.first_name,
                last_name: @lead.last_name,
                email: @lead.email,
                phone: @lead.phone,
                account_id: account.id,
                company_id: @lead.company_id,
                location_id: location_id,
                owner_id: inherited_owner_id,
                is_primary: true,
                notes: "Converted from lead ##{@lead.id}",
                # Copy lead address → contact billing address
                street: @lead.street,
                city: @lead.city,
                state: @lead.state,
                zip: @lead.zip,
                country: @lead.country
              }
              contact_attrs[:title] = @lead.title if @lead.try(:title).present? && Contact.column_names.include?('title')

              contact = Contact.new(contact_attrs)
              
              if contact.save
                Rails.logger.info "✅ [ConvertLead] Contact created: #{contact.id}"
              else
                Rails.logger.warn "⚠️  [ConvertLead] Contact creation failed: #{contact.errors.full_messages}"
                contact = nil
              end
            else
              Rails.logger.info "⏭️  [ConvertLead] Skipping contact creation (not requested)"
            end

            # 2b. CREATE CO-APPLICANT CONTACT (co-borrower) — a second contact on
            # the same account. Only when the lead captured co-applicant identity.
            co_applicant = nil
            if @lead.respond_to?(:co_applicant_first_name) &&
               (@lead.co_applicant_first_name.present? || @lead.co_applicant_last_name.present?)
              Rails.logger.info "✅ [ConvertLead] Creating co-applicant contact"

              co_applicant = Contact.new(
                first_name: @lead.co_applicant_first_name.presence || 'Co-Applicant',
                last_name:  @lead.co_applicant_last_name,
                email:      @lead.co_applicant_email,
                phone:      @lead.co_applicant_phone,
                account_id: account.id,
                company_id: @lead.company_id,
                location_id: location_id,
                owner_id:   inherited_owner_id,
                is_primary: false,
                notes: "Co-applicant converted from lead ##{@lead.id}",
                # Share the household address with the primary applicant
                street: @lead.street, city: @lead.city, state: @lead.state,
                zip: @lead.zip, country: @lead.country
              )

              if co_applicant.save
                Rails.logger.info "✅ [ConvertLead] Co-applicant contact created: #{co_applicant.id}"
              else
                Rails.logger.warn "⚠️  [ConvertLead] Co-applicant creation failed: #{co_applicant.errors.full_messages}"
                co_applicant = nil
              end
            end

            # 3. CREATE DEAL (if requested)
            deal = nil
            deal_error = nil
            if params[:create_deal].present? && params[:create_deal].is_a?(ActionController::Parameters)
              deal_params = params[:create_deal]

              Rails.logger.info "✅ [ConvertLead] Creating deal with params: #{deal_params.inspect}"

              # Stage must be one the company actually configured, otherwise the
              # Deal stage validation rejects it and the deal is silently dropped.
              # Honor a valid requested stage; fall back to the company default.
              requested_stage = deal_params[:stage].to_s.strip
              stage = @company.valid_pipeline_stage?(requested_stage) ?
                requested_stage.downcase : @company.default_deal_stage
              Rails.logger.info "✅ [ConvertLead] Resolved deal stage: #{stage} (requested: #{requested_stage.presence || 'none'})"

              deal = Deal.new(
                name: deal_params[:name].presence || "#{account_name} Opportunity",
                account_id: account.id,
                contact_id: contact&.id,
                company_id: @lead.company_id,
                location_id: location_id,
                stage: stage,
                value: 0, # Will be updated when products/pricing added to deal
                expected_close_date: deal_params[:close_date] || deal_params[:expected_close],
                owner_id: inherited_owner_id,
                user_id: inherited_owner_id,
                description: deal_params[:description] || "Converted from lead ##{@lead.id}",
                vehicle_id: @lead.vehicle_id,  # Carry over vehicle from lead
                # Copy lead address → deal billing address
                billing_street: @lead.street,
                billing_city: @lead.city,
                billing_state: @lead.state,
                billing_zip: @lead.zip,
                billing_country: @lead.country
              )

              if deal.save
                Rails.logger.info "✅ [ConvertLead] Deal created: #{deal.id}"
              else
                deal_error = deal.errors.full_messages.join(', ')
                Rails.logger.warn "⚠️  [ConvertLead] Deal creation failed: #{deal_error}"
                deal = nil
              end
            else
              Rails.logger.info "⏭️  [ConvertLead] Skipping deal creation (not requested)"
            end
            
            # 4. MIGRATE ACTIVITIES
            if defined?(LeadActivity) && defined?(AccountActivity)
              activity_count = @lead.lead_activities.count
              Rails.logger.info "🔄 [ConvertLead] Migrating #{activity_count} activities"
              
              @lead.lead_activities.each do |la|
                aa = AccountActivity.new(
                  account_id: account.id,
                  user_id: la.user_id,
                  assigned_to_id: la.assigned_to_id,
                  activity_type: la.activity_type,
                  subject: la.subject,
                  # account_activities.description is NOT NULL but lead_activities
                  # allows null — copying a null straight over aborts the whole
                  # conversion transaction. Fall back to the subject/type so the
                  # activity migrates instead of killing the conversion.
                  description: la.description.presence || la.subject.presence || la.activity_type.to_s.humanize.presence || 'Activity',
                  status: la.status,
                  priority: la.priority,
                  due_date: la.due_date,
                  start_time: la.start_time,
                  end_time: la.end_time,
                  duration_minutes: la.duration_minutes,
                  completed_at: la.completed_at,
                  call_direction: la.call_direction,
                  call_outcome: la.call_outcome,
                  phone_number: la.phone_number,
                  meeting_location: la.meeting_location,
                  meeting_link: la.meeting_link,
                  meeting_attendees: la.meeting_attendees,
                  reminder_method: la.reminder_method,
                  reminder_time: la.reminder_time,
                  reminder_sent: la.reminder_sent,
                  estimated_hours: la.estimated_hours,
                  actual_hours: la.actual_hours,
                  outcome_notes: la.outcome_notes,
                  metadata: la.metadata,
                  created_at: la.created_at,
                  updated_at: la.updated_at
                )
                
                aa.save
              end
              
              Rails.logger.info "✅ [ConvertLead] Migrated #{activity_count} activities"
            end
            
            # 5. COPY CUSTOM FIELD VALUES VIA MIGRATION MAPPINGS
            cf_result = CustomFieldMigrationService.copy_values(
              @lead, contact: contact, account: account, deal: deal
            )
            Rails.logger.info "🔄 [ConvertLead] Custom field migration: copied=#{cf_result[:copied]}, gaps=#{cf_result[:gaps].size}"

            # 6. MARK LEAD AS CONVERTED
            @lead.update!(
              is_converted: true,
              converted_at: Time.current,
              converted_account_id: account.id
            )

            Rails.logger.info "🎉 [ConvertLead] Conversion complete!"

            # Return response
            render json: {
              account: {
                id: account.id,
                name: account.name,
                email: account.email,
                phone: account.phone,
                status: account.status
              },
              contact: contact ? {
                id: contact.id,
                firstName: contact.first_name,
                lastName: contact.last_name,
                email: contact.email,
                phone: contact.phone,
                accountId: contact.account_id
              } : nil,
              coApplicant: co_applicant ? {
                id: co_applicant.id,
                firstName: co_applicant.first_name,
                lastName: co_applicant.last_name,
                email: co_applicant.email,
                phone: co_applicant.phone,
                accountId: co_applicant.account_id
              } : nil,
              deal: deal ? {
                id: deal.id,
                name: deal.name,
                stage: deal.stage,
                value: deal.value,
                expectedCloseDate: deal.expected_close_date,
                accountId: deal.account_id,
                contactId: deal.contact_id
              } : nil,
              # Non-fatal: account/contact still converted, but the requested
              # deal could not be created. Surface so the UI stops reporting a
              # clean success when a deal was expected.
              dealError: deal_error,
              customFieldGaps: cf_result[:gaps]
            }, status: :ok
          end
          
        rescue => e
          Rails.logger.error "❌ [ConvertLead] Error: #{e.message}"
          Rails.logger.error e.backtrace.first(10).join("\n")
          render json: { error: "Conversion failed: #{e.message}" }, status: :internal_server_error
        end
      end

      # GET /api/crm/leads/:id/conversion_integrity_check
      def conversion_integrity_check
        return unless authorize_action!('leads', 'read')

        gaps = CustomFieldMigrationService.check_integrity(@lead)
        render json: { gaps: gaps }
      end

      # POST /api/crm/leads/check_duplicates
      # Soft duplicate lookup used by the New Lead form. Searches existing leads
      # in the current company for a matching email or phone and returns any
      # matches (non-blocking — the UI shows a warning, never prevents save).
      def check_duplicates
        return unless authorize_action!('leads', 'read')

        email = params[:email].to_s.strip.downcase
        phone = normalize_phone(params[:phone])

        if email.blank? && phone.blank?
          render json: { duplicates: [] }
          return
        end

        # STRICT TENANT ISOLATION: only this company's leads.
        scope = @company.leads.where(is_converted: [false, nil])

        conditions = []
        values     = []
        if email.present?
          conditions << 'LOWER(email) = ?'
          values << email
        end
        if phone.present?
          # Compare on digits only so (303) 555-1212 matches 3035551212.
          conditions << "regexp_replace(COALESCE(phone, ''), '[^0-9]', '', 'g') = ?"
          values << phone
        end

        matches = scope.where(conditions.join(' OR '), *values).limit(5)

        same_type = matches.map { |l| duplicate_match_json(l, email, phone) }

        # Cross-entity awareness: also surface contacts/accounts that share this
        # email/phone so the user knows the person already exists elsewhere.
        # These are WARNINGS only (never block). Tagged with entityType so the
        # frontend can label and link them correctly.
        cross = IdentityResolver.new(@company, email: email, phone: phone)
                                .all(exclude: nil)
                                .reject { |m| m.type == :lead }
                                .map { |m| cross_entity_json(m) }

        render json: { duplicates: same_type + cross }
      rescue => e
        Rails.logger.error "[LeadsController#check_duplicates] #{e.class}: #{e.message}"
        render json: { duplicates: [] }
      end

      private

      # Per-tenant list of status keys flagged as dead-end (is_excluded=true on
      # lead_statuses). Admins manage this via the Lead Statuses tab — adding a
      # custom "Cold Storage" status with is_excluded=true here flows through to
      # the leads filter automatically. Memoized per-request.
      def excluded_status_keys
        @excluded_status_keys ||= begin
          keys = @company.lead_statuses.excluded.pluck(:key)
          keys.presence || DEFAULT_EXCLUDED_STATUSES
        end
      end

      # Tenant + RBAC + location-selector scoped lead set, BEFORE per-request filters
      # (status_category / search / owner_id). Shared by #index and #bulk_reassign so a
      # user can't bulk-reassign a lead they wouldn't see in the list.
      def base_leads_scope
        leads = if current_user.uses_rbac?
                  if current_user.effective_admin?
                    @company.leads.where(is_converted: [false, nil])
                  elsif permission_service.can?('leads', 'read', 'all')
                    @company.leads.where(is_converted: [false, nil])
                  else
                    location_ids = permission_service.accessible_location_ids
                    if location_ids.any?
                      @company.leads.where(is_converted: [false, nil], location_id: location_ids)
                    else
                      @company.leads.where(is_converted: [false, nil])
                    end
                  end
                else
                  @company.leads.where(is_converted: [false, nil])
                end
        leads.for_current_location
      end

      # Apply the same filters #index uses so #bulk_reassign's "select all matching"
      # path acts on exactly the visible set.
      # Whitelist of sortable columns from the leads table header. Maps the
      # frontend column id to a SQL expression so we can sort across the
      # full filtered set (not just the current page). Anything not in this
      # map falls back to the default created-at order.
      SORTABLE_COLUMNS = {
        'firstName'    => 'first_name',
        'lastName'     => 'last_name',
        'companyName'  => 'company_name',
        'email'        => 'email',
        'phone'        => 'phone',
        'status'       => 'status',
        'health_score' => 'health_score',
        'createdAt'    => 'COALESCE(source_created_at, created_at)',
        'lastActivity' => 'last_activity_at',
        # owner sorts on the joined users row (see left_outer_joins below);
        # first_name is enough — ties break naturally on the next column we apply.
        'owner'        => 'users.first_name',
      }.freeze

      DEFAULT_SORT_SQL = 'COALESCE(source_created_at, created_at) DESC'

      def apply_index_sort(scope, sort_key, order)
        column_sql = SORTABLE_COLUMNS[sort_key.to_s]
        return scope.order(Arel.sql(DEFAULT_SORT_SQL)) unless column_sql

        direction = order.to_s.downcase == 'desc' ? 'DESC' : 'ASC'
        scope = scope.left_outer_joins(:owner) if sort_key.to_s == 'owner'

        # NULLS LAST for both directions so empty values sink to the bottom
        # regardless of asc/desc — matches what users expect from spreadsheets.
        scope.order(Arel.sql("#{column_sql} #{direction} NULLS LAST"))
      end

      # Health band thresholds — must match bandFromScore() in
      # LeadHealthBadge.tsx so the dropdown labels and the server filter agree.
      HEALTH_BAND_RANGES = {
        'hot'      => (80..),
        'warm'     => (60..79),
        'lukewarm' => (40..59),
        'cold'     => (20..39),
        'dead'     => (0..19),
      }.freeze

      def apply_index_filters(scope, filters)
        if filters[:status_category].to_s == 'active'
          scope = scope.where.not(status: excluded_status_keys)
        end

        if filters[:search].present?
          q = "%#{filters[:search]}%"
          scope = scope.where(
            'first_name ILIKE ? OR last_name ILIKE ? OR email ILIKE ? OR phone ILIKE ? OR status ILIKE ?',
            q, q, q, q, q
          )
        end

        if filters[:owner_id].present?
          # 'unassigned' sentinel matches leads with no owner; numeric ids filter to that owner.
          scope = filters[:owner_id].to_s == 'unassigned' ? scope.where(owner_id: nil) : scope.where(owner_id: filters[:owner_id])
        end

        if (range = HEALTH_BAND_RANGES[filters[:health_band].to_s])
          scope = scope.where(health_score: range)
        end

        scope
      end

      # Shape a cross-entity IdentityResolver match for the dedupe UI. entityType
      # tells the frontend it's a different object type (contact/account) so it
      # can label it "exists as a Contact" and link to the right detail page.
      def cross_entity_json(match)
        {
          id: match.record.id,
          firstName: match.record.try(:first_name),
          lastName: match.record.try(:last_name),
          name: match.name.presence,
          email: match.record.try(:email),
          phone: match.record.try(:phone),
          matchedField: match.matched,
          entityType: match.type.to_s,
          converted: match.converted
        }
      end

      # Strip everything but digits for forgiving phone comparison.
      def normalize_phone(raw)
        raw.to_s.gsub(/[^0-9]/, '')
      end

      # Minimal match payload for the dedupe warning UI.
      def duplicate_match_json(lead, email, phone)
        lead_phone_digits = normalize_phone(lead.phone)
        matched = if email.present? && lead.email.to_s.downcase == email
                    'email'
                  elsif phone.present? && lead_phone_digits == phone
                    'phone'
                  else
                    'email'
                  end
        {
          id: lead.id,
          firstName: lead.first_name,
          lastName: lead.last_name,
          email: lead.email,
          phone: lead.phone,
          status: lead.status,
          matchedField: matched
        }
      end

      def set_company_scope
        unless current_user
          Rails.logger.error "🚫 [LeadsController] No authenticated user found"
          render json: { error: 'Authentication required' }, status: :unauthorized
          return
        end
        
        # Use current_company_id which respects X-Company-ID header for platform admins
        company_id = current_company_id
        
        unless company_id.present?
          Rails.logger.error "🚫 [LeadsController] No company context available"
          render json: { error: 'No company context' }, status: :forbidden
          return
        end
        
        @company = ::Company.find_by(id: company_id)
        
        if @company.nil?
          Rails.logger.error "🚫 [LeadsController] Company #{company_id} not found"
          render json: { error: 'Company not found' }, status: :not_found
          return
        end
        
        Rails.logger.info "✅ [LeadsController] Company scope set: #{@company.name} (ID: #{@company.id})"
      end

      def set_lead
        # STRICT TENANT ISOLATION: Only access leads in same company
        # RBAC: Location-tier users only access their assigned locations
        # BUT: Users with :all scope access ALL leads (company-wide)
        @lead = if current_user.uses_rbac? && !current_user.effective_admin?
          # Check if user has company-wide scope (:all) for leads
          has_all_scope = permission_service.can?('leads', 'read', 'all')
          
          if has_all_scope
            # User has company-wide access
            Rails.logger.info "[LeadsController#set_lead] User has leads:read:all - accessing any company lead"
            @company.leads.includes(:source, :owner, :vehicle).find(params[:id])
          else
            # User is location-restricted
            location_ids = permission_service.accessible_location_ids
            Rails.logger.info "[LeadsController#set_lead] User has location scope - accessible_location_ids: #{location_ids.inspect}"
            if location_ids.any?
              @company.leads.includes(:source, :owner, :vehicle).where(location_id: location_ids).find(params[:id])
            else
              @company.leads.includes(:source, :owner, :vehicle).find(params[:id])
            end
          end
        else
          @company.leads.includes(:source, :owner, :vehicle).find(params[:id])
        end
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Lead not found or access denied' }, status: :not_found
        return
      end

      # Merge root + nested (:lead), accept camel & snake, normalize to snake.
      def lead_params
        # CRITICAL: company_id is NEVER updatable - it's set at creation from @company.id
        # Allowing company_id in params breaks tenant isolation!
        allowed = [:first_name, :last_name, :email, :phone, :notes, :source_id, :status, :owner_id,
                   :firstName, :lastName, :sourceId, :ownerId,
                   :budget_range, :budgetRange, :purchase_timeframe, :purchaseTimeframe,
                   :rv_experience, :rvExperience, :preferred_contact_method, :preferredContactMethod,
                   :interests_requirements, :interestsRequirements,
                   :vehicle_id, :vehicleId,
                   # Inventory preferences
                   :preferred_bedrooms, :preferredBedrooms,
                   :preferred_bathrooms, :preferredBathrooms,
                   :preferred_min_sqft, :preferredMinSqft,
                   :preferred_max_sqft, :preferredMaxSqft,
                   :preferred_home_type, :preferredHomeType,
                   # Company/title (org context for B2B-style leads)
                   :company_name, :companyName, :title,
                   # Co-applicant (co-borrower) identity → becomes a 2nd contact on conversion
                   :co_applicant_first_name, :coApplicantFirstName,
                   :co_applicant_last_name,  :coApplicantLastName,
                   :co_applicant_email,      :coApplicantEmail,
                   :co_applicant_phone,      :coApplicantPhone,
                   # Address fields
                   :street, :city, :state, :zip, :country]

        root = params.permit(*allowed, lead: {})
        nested = params[:lead].is_a?(ActionController::Parameters) ? params.require(:lead).permit(*allowed) : {}

        raw = root.to_h.merge(nested.to_h) # nested wins if both present

        {
          first_name: raw['first_name'] || raw['firstName'],
          last_name:  raw['last_name']  || raw['lastName'],
          email:      raw['email'],
          phone:      raw['phone'],
          notes:      raw['notes'],
          status:     raw['status'],
          # company_id is EXCLUDED - never updatable!
          source_id:  (raw['source_id']  || raw['sourceId']).presence&.to_i,
          owner_id:   (raw['owner_id']   || raw['ownerId']).presence&.to_i,
          # NEW FIELDS for lead qualification
          budget_range: raw['budget_range'] || raw['budgetRange'],
          purchase_timeframe: raw['purchase_timeframe'] || raw['purchaseTimeframe'],
          rv_experience: raw['rv_experience'] || raw['rvExperience'],
          preferred_contact_method: raw['preferred_contact_method'] || raw['preferredContactMethod'],
          interests_requirements: raw['interests_requirements'] || raw['interestsRequirements'],
          vehicle_id: (raw['vehicle_id'] || raw['vehicleId']).presence&.to_i,
          # Inventory preferences
          preferred_bedrooms:  (raw['preferred_bedrooms']  || raw['preferredBedrooms']).presence&.to_i,
          preferred_bathrooms: (raw['preferred_bathrooms'] || raw['preferredBathrooms']).presence&.to_i,
          preferred_min_sqft:  (raw['preferred_min_sqft']  || raw['preferredMinSqft']).presence&.to_i,
          preferred_max_sqft:  (raw['preferred_max_sqft']  || raw['preferredMaxSqft']).presence&.to_i,
          preferred_home_type: raw['preferred_home_type'] || raw['preferredHomeType'],
          # Company / job title (free-text, distinct from the tenant company_id)
          company_name: raw['company_name'] || raw['companyName'],
          title:        raw['title'],
          # Co-applicant identity
          co_applicant_first_name: raw['co_applicant_first_name'] || raw['coApplicantFirstName'],
          co_applicant_last_name:  raw['co_applicant_last_name']  || raw['coApplicantLastName'],
          co_applicant_email:      raw['co_applicant_email']      || raw['coApplicantEmail'],
          co_applicant_phone:      raw['co_applicant_phone']      || raw['coApplicantPhone'],
          # Address
          street:  raw['street'],
          city:    raw['city'],
          state:   raw['state'],
          zip:     raw['zip'],
          country: raw['country']
        }.compact
      end

      def custom_field_values_param
        raw = params[:custom_field_values] || params[:customFieldValues]
        return {} if raw.blank?
        raw.is_a?(ActionController::Parameters) ? raw.to_unsafe_h : raw.to_h
      end

      def validate_custom_field_values(module_name, values, partial: false)
        return [] if values.blank?

        errors = []
        @company.custom_fields.active.for_module(module_name).each do |field|
          # For partial updates (inline edit), only validate fields actually submitted
          next if partial && !values.key?(field.field_key)

          value = values[field.field_key]
          field_errors = field.validate_value(value)
          errors.concat(field_errors)
        end
        errors
      end

      def calculate_lead_score(lead)
        score = 0
        score += 20 if lead.email.present?
        score += 15 if lead.phone.present?
        score += 25 if lead.source_id.present?
        score += 20 if lead.notes.present?
        score += 20 if lead.status.present? && lead.status != 'new'
        score
      end
      
      def calculate_percentage_change(previous_value, current_value)
        return '+0%' if previous_value.zero? && current_value.zero?
        return '+100%' if previous_value.zero? && current_value > 0
        return '-100%' if current_value.zero? && previous_value > 0
        
        change = ((current_value - previous_value).to_f / previous_value * 100).round
        change >= 0 ? "+#{change}%" : "#{change}%"
      end

      def lead_json(l)
        owner_data = if l.owner
          {
            id: l.owner.id,
            name: "#{l.owner.first_name} #{l.owner.last_name}".strip,
            email: l.owner.email
          }
        else
          nil
        end
        
        {
          id:        l.id,
          firstName: l.first_name,
          lastName:  l.last_name,
          email:     l.email,
          phone:     l.phone,
          notes:     l.notes,
          status:    l.status,
          companyName: l.company_name,
          title:       l.title,
          sourceId:  l.source_id,
          source:    (l.source ? { id: l.source.id, name: l.source.name } : nil),
          ownerId:   l.owner_id,
          owner:     owner_data,
          isConverted: l.respond_to?(:is_converted) ? l.is_converted : false,
          convertedAt: l.respond_to?(:converted_at) ? l.converted_at : nil,
          convertedToAccountId: l.respond_to?(:converted_account_id) ? l.converted_account_id : nil,
          # NEW FIELDS
          budgetRange: l.respond_to?(:budget_range) ? l.budget_range : nil,
          purchaseTimeframe: l.respond_to?(:purchase_timeframe) ? l.purchase_timeframe : nil,
          rvExperience: l.respond_to?(:rv_experience) ? l.rv_experience : nil,
          preferredContactMethod: l.respond_to?(:preferred_contact_method) ? l.preferred_contact_method : nil,
          interestsRequirements: l.respond_to?(:interests_requirements) ? l.interests_requirements : nil,
          vehicleId: l.vehicle_id,
          preferredBedrooms:  l.respond_to?(:preferred_bedrooms)  ? l.preferred_bedrooms  : nil,
          preferredBathrooms: l.respond_to?(:preferred_bathrooms) ? l.preferred_bathrooms : nil,
          preferredMinSqft:   l.respond_to?(:preferred_min_sqft)  ? l.preferred_min_sqft  : nil,
          preferredMaxSqft:   l.respond_to?(:preferred_max_sqft)  ? l.preferred_max_sqft  : nil,
          preferredHomeType:  l.respond_to?(:preferred_home_type) ? l.preferred_home_type : nil,
          vehicle: l.vehicle ? {
            id: l.vehicle.id,
            inventoryId: l.vehicle.inventory_id,
            displayName: l.vehicle.display_name,
            year: l.vehicle.year,
            make: l.vehicle.make,
            model: l.vehicle.model,
            status: l.vehicle.status,
            listingType: l.vehicle.listing_type,
            salePrice: l.vehicle.sale_price,
            msrp: l.vehicle.msrp
          } : nil,
          # Address
          street: l.street,
          city: l.city,
          state: l.state,
          zip: l.zip,
          country: l.country,
          # Co-applicant (co-borrower) identity
          coApplicantFirstName: l.respond_to?(:co_applicant_first_name) ? l.co_applicant_first_name : nil,
          coApplicantLastName:  l.respond_to?(:co_applicant_last_name)  ? l.co_applicant_last_name  : nil,
          coApplicantEmail:     l.respond_to?(:co_applicant_email)      ? l.co_applicant_email      : nil,
          coApplicantPhone:     l.respond_to?(:co_applicant_phone)      ? l.co_applicant_phone      : nil,
          customFieldValues: l.respond_to?(:custom_field_values) ? l.custom_field_values : {},
          # Champion Leads API fields
          champion_salesforce_id: l.champion_salesforce_id,
          champion_status: l.champion_status,
          champion_lead_data: l.champion_lead_data,
          champion_config_id: l.champion_config_id,
          champion_accepted_at: l.champion_accepted_at,
          champion_declined_at: l.champion_declined_at,
          champion_action_token: l.champion_action_token,
          champion_action_token_expires_at: l.champion_action_token_expires_at,
          score: l.lead_scores.max_by(&:updated_at)&.score,
          # Lead health (hot/warm/lukewarm/cold/dead). Frontend computes the band
          # label from healthScore via bandFromScore() — same thresholds we use
          # server-side in apply_index_filters for the health_band filter.
          healthScore: l.health_score,
          tags: l.tags.map { |t| { id: t.id, name: t.name, color: t.respond_to?(:color) ? t.color : nil } },
          createdAt: l.created_at,
          sourceCreatedAt: l.source_created_at,
          updatedAt: l.updated_at,
          lastActivityAt: l.last_activity_at,
        }
      end
    end
  end
end
