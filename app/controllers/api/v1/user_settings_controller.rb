# frozen_string_literal: true

module Api
  module V1
    class UserSettingsController < ApplicationController
      skip_before_action :authenticate
      before_action :authenticate_any_user
      before_action :set_user

      # GET /api/v1/user_settings/profile
      def profile
        render json: {
          id: @user.id,
          email: @user.email,
          first_name: extract_first_name,
          last_name: extract_last_name,
          title: @user.respond_to?(:title) ? @user.title : nil,
          phone: extract_phone,
          address: extract_address,
          city: extract_city,
          state: extract_state,
          zip: extract_zip,
          user_type: @user_type,
          landing_page: @user.respond_to?(:landing_page) ? @user.landing_page : nil,
          booking_url: @user.respond_to?(:booking_url) ? @user.booking_url : nil,
          workqueue_preferences: @user.respond_to?(:workqueue_preferences) ? (@user.workqueue_preferences || {}) : {},
          calendar_preferences: @user.respond_to?(:calendar_preferences) ? (@user.calendar_preferences || {}) : {}
        }, status: :ok
      end

      # PATCH /api/v1/user_settings/profile
      def update_profile
        profile_params = params.permit(
          :first_name, :last_name, :title, :phone, :email, :address, :city, :state, :zip, :landing_page, :booking_url,
          workqueue_preferences: {}, calendar_preferences: {}
        )

        begin
          if @user_type == 'client'
            # For BuyerPortalAccess, update the user and associated contact
            updates = {}
            updates[:email] = profile_params[:email] if profile_params[:email].present?
            
            @user.update!(updates) if updates.any?
            
            if @user.buyer && @user.buyer.is_a?(Contact)
              contact = @user.buyer
              contact_updates = {}
              contact_updates[:first_name] = profile_params[:first_name] if profile_params[:first_name].present?
              contact_updates[:last_name] = profile_params[:last_name] if profile_params[:last_name].present?
              contact_updates[:phone] = profile_params[:phone] if profile_params[:phone].present?
              contact_updates[:address] = profile_params[:address] if profile_params[:address].present?
              contact_updates[:city] = profile_params[:city] if profile_params[:city].present?
              contact_updates[:state] = profile_params[:state] if profile_params[:state].present?
              contact_updates[:zip] = profile_params[:zip] if profile_params[:zip].present?
              
              contact.update!(contact_updates) if contact_updates.any?
            end
          else
            # For User model - only update provided fields
            updates = {}
            updates[:first_name] = profile_params[:first_name] if profile_params[:first_name].present?
            updates[:last_name] = profile_params[:last_name] if profile_params[:last_name].present?
            updates[:title] = profile_params[:title] if profile_params.key?(:title)
            updates[:phone] = profile_params[:phone] if profile_params[:phone].present?
            updates[:email] = profile_params[:email] if profile_params[:email].present?
            updates[:landing_page] = profile_params[:landing_page] if profile_params[:landing_page].present?
            updates[:booking_url] = profile_params[:booking_url] if profile_params.key?(:booking_url)

            if params.key?(:workqueue_preferences) && @user.respond_to?(:workqueue_preferences)
              raw = profile_params[:workqueue_preferences] || {}
              sanitized = sanitize_workqueue_preferences(raw)
              # Merge into existing prefs — a PATCH that touches just
              # lead_kanban_hidden_columns shouldn't wipe out the user's
              # numeric workqueue settings or hidden_queues.
              existing = (@user.workqueue_preferences || {}).symbolize_keys
              updates[:workqueue_preferences] = existing.merge(sanitized)
            end

            if params.key?(:calendar_preferences) && @user.respond_to?(:calendar_preferences)
              raw = profile_params[:calendar_preferences] || {}
              sanitized = sanitize_calendar_preferences(raw)
              existing = (@user.calendar_preferences || {}).symbolize_keys
              updates[:calendar_preferences] = existing.merge(sanitized)
            end

            @user.update!(updates) if updates.any?
          end

          render json: {
            success: true,
            message: 'Profile updated successfully'
          }, status: :ok
        rescue ActiveRecord::RecordInvalid => e
          render json: {
            success: false,
            error: e.record.errors.full_messages.join(', ')
          }, status: :unprocessable_entity
        rescue StandardError => e
          Rails.logger.error("Profile update error: #{e.message}")
          render json: {
            success: false,
            error: 'Failed to update profile'
          }, status: :internal_server_error
        end
      end

      # POST /api/v1/user_settings/change_password
      def change_password
        current_password = params[:current_password]
        new_password = params[:new_password]

        # Validate parameters
        if current_password.blank? || new_password.blank?
          render json: {
            success: false,
            error: 'Current password and new password are required'
          }, status: :bad_request
          return
        end

        if new_password.length < 6
          render json: {
            success: false,
            error: 'Password must be at least 6 characters'
          }, status: :unprocessable_entity
          return
        end

        # Verify current password
        unless @user.authenticate(current_password)
          render json: {
            success: false,
            error: 'Current password is incorrect'
          }, status: :unprocessable_entity
          return
        end

        # Update password
        begin
          @user.update!(password: new_password)

          # Log the password change
          log_password_change

          render json: {
            success: true,
            message: 'Password changed successfully'
          }, status: :ok
        rescue StandardError => e
          Rails.logger.error("Password change error: #{e.message}")
          render json: {
            success: false,
            error: 'Failed to change password'
          }, status: :internal_server_error
        end
      end

      # GET /api/v1/user_settings/security
      def security
        render json: {
          mfa_enabled: @user.mfa_enabled || false,
          mfa_method: @user.mfa_method || 'email',
          has_email: @user.email.present?,
          has_phone: extract_phone.present?,
          email: @user.email,
          phone: extract_phone
        }, status: :ok
      end

      # PATCH /api/v1/user_settings/security
      def update_security
        enabled = params[:mfa_enabled]
        method = params[:mfa_method]

        if enabled.nil?
          render json: {
            success: false,
            error: 'MFA enabled parameter is required'
          }, status: :bad_request
          return
        end

        # Convert to boolean
        enabled = ActiveModel::Type::Boolean.new.cast(enabled)

        # Validate method if MFA is being enabled
        if enabled && method.present? && !%w[email sms].include?(method)
          render json: {
            success: false,
            error: 'Invalid MFA method. Must be email or sms'
          }, status: :bad_request
          return
        end

        # Check if user has the required contact info for the method
        if enabled
          if method == 'sms' && extract_phone.blank?
            render json: {
              success: false,
              error: 'Phone number is required for SMS verification'
            }, status: :unprocessable_entity
            return
          elsif method == 'email' && @user.email.blank?
            render json: {
              success: false,
              error: 'Email address is required for email verification'
            }, status: :unprocessable_entity
            return
          end
        end

        begin
          @user.update!(
            mfa_enabled: enabled,
            mfa_method: method || @user.mfa_method || 'email'
          )

          # Log the MFA change
          log_mfa_change(enabled)

          render json: {
            success: true,
            message: enabled ? 'MFA has been enabled' : 'MFA has been disabled',
            mfa_enabled: @user.mfa_enabled,
            mfa_method: @user.mfa_method
          }, status: :ok
        rescue StandardError => e
          Rails.logger.error("Security update error: #{e.message}")
          render json: {
            success: false,
            error: 'Failed to update security settings'
          }, status: :internal_server_error
        end
      end

      # GET /api/v1/user_settings/login_activity
      def login_activity
        # Get user's login history (last 3 sessions)
        recent_sessions = LoginActivity
          .for_user(@user.id, @user_type == 'client' ? 'BuyerPortalAccess' : 'User')
          .recent
          .limit(3)
          .map do |activity|
            {
              device: activity.user_agent || 'Unknown device',
              ip_address: activity.ip_address,
              logged_in_at: activity.logged_in_at.iso8601,
              status: 'completed'
            }
          end
        
        # Current session info
        current_session = {
          device: request.user_agent,
          ip_address: request.remote_ip,
          logged_in_at: Time.current.iso8601,
          status: 'active'
        }

        render json: {
          current_session: current_session,
          recent_sessions: recent_sessions
        }, status: :ok
      end

      # GET /api/v1/user_settings/notifications
      def notifications
        if @user_type == 'client'
          # For portal users, get notification preferences from BuyerPortalAccess
          render json: {
            email_notifications: @user.email_opt_in != false,
            sms_notifications: @user.sms_opt_in == true,
            marketing_emails: @user.marketing_opt_in == true
          }, status: :ok
        else
          # For admin users, return defaults (could be extended later)
          render json: {
            email_notifications: true,
            sms_notifications: false,
            marketing_emails: false
          }, status: :ok
        end
      end

      # PATCH /api/v1/user_settings/notifications
      def update_notifications
        begin
          if @user_type == 'client'
            # Update portal user notification preferences
            updates = {}
            updates[:email_opt_in] = params[:email_notifications] if params.key?(:email_notifications)
            updates[:sms_opt_in] = params[:sms_notifications] if params.key?(:sms_notifications)
            updates[:marketing_opt_in] = params[:marketing_emails] if params.key?(:marketing_emails)
            
            @user.update!(updates) if updates.any?
            
            render json: {
              success: true,
              message: 'Notification preferences updated successfully'
            }, status: :ok
          else
            # Admin users - not implemented yet
            render json: {
              success: true,
              message: 'Notification preferences updated'
            }, status: :ok
          end
        rescue StandardError => e
          Rails.logger.error("Notification update error: #{e.message}")
          render json: {
            success: false,
            error: 'Failed to update notification preferences'
          }, status: :internal_server_error
        end
      end

      # POST /api/v1/user_settings/test_digest
      def test_digest
        unless @user_type == 'admin'
          return render json: { success: false, error: 'Not available for portal users' }, status: :forbidden
        end

        unless @user.respond_to?(:has_email_connection?) && @user.has_email_connection?
          return render json: {
            success: false,
            error: 'No email connection configured. Connect Gmail or Outlook in Account Settings.'
          }, status: :unprocessable_entity
        end

        result = DailyDigestService.new(@user).send_digest!

        if result[:success]
          render json: { success: true, message: 'Digest email sent to ' + @user.email }
        else
          render json: { success: false, error: result[:error] }, status: :unprocessable_entity
        end
      rescue => e
        Rails.logger.error('[test_digest] Error: ' + e.message)
        render json: { success: false, error: e.message }, status: :internal_server_error
      end

      private

      # Coerces and constrains workqueue_preferences input so users can't
      # store arbitrary data on their row.
      def sanitize_workqueue_preferences(raw)
        raw = raw.to_unsafe_h if raw.respond_to?(:to_unsafe_h)
        raw = raw.symbolize_keys

        allowed_numeric_keys = %i[
          new_leads_days
          stale_leads_days
          stale_deals_days
          reminders_window_days
          meetings_window_days
          closing_week_days
          tasks_week_days
          replied_window_days
        ]

        # Derived from WorkqueueService::QUEUES rather than hand-listed: this is
        # the allowlist for the &-filter below, so any queue missing from it has
        # its visibility change silently discarded — the user unchecks a queue,
        # gets "Preferences saved", and it's still there on reload. Deriving it
        # means adding a queue can never reintroduce that.
        valid_queue_ids = WorkqueueService::QUEUES.keys.map(&:to_s)

        result = {}

        allowed_numeric_keys.each do |key|
          next unless raw.key?(key)
          value = raw[key].to_i
          # Clamp to 1..365 days so a fat-fingered 999999 doesn't wreck queries.
          result[key] = value.clamp(1, 365)
        end

        # Boolean toggle: when true (default), the sidebar shows every enabled
        # queue even if it currently has 0 items. When false, empty queues
        # auto-hide until they get data.
        if raw.key?(:show_empty_queues)
          result[:show_empty_queues] = ActiveModel::Type::Boolean.new.cast(raw[:show_empty_queues])
        end

        if raw.key?(:hidden_queues)
          hidden = Array(raw[:hidden_queues]).map(&:to_s)
          result[:hidden_queues] = hidden & valid_queue_ids
        end

        # Per-user list of lead_status keys hidden from the leads Kanban view.
        # Values aren't allowlisted because lead_statuses are tenant-configurable;
        # cap length and string-coerce to prevent abuse.
        if raw.key?(:lead_kanban_hidden_columns)
          arr = Array(raw[:lead_kanban_hidden_columns]).map(&:to_s)
          result[:lead_kanban_hidden_columns] = arr.first(200)
        end

        # Per-user hidden-columns list for the leads list (table) view and
        # hidden-fields list for the leads tile/cards view. Column/field ids
        # are stable, defined in CRMProspecting.tsx; cap length to prevent abuse.
        if raw.key?(:lead_table_hidden_columns)
          arr = Array(raw[:lead_table_hidden_columns]).map(&:to_s)
          result[:lead_table_hidden_columns] = arr.first(100)
        end
        if raw.key?(:lead_cards_hidden_fields)
          arr = Array(raw[:lead_cards_hidden_fields]).map(&:to_s)
          result[:lead_cards_hidden_fields] = arr.first(100)
        end

        # Same pattern for the deals list (table) and cards view. Ids defined
        # in CRMSalesDeal.tsx.
        if raw.key?(:deal_table_hidden_columns)
          arr = Array(raw[:deal_table_hidden_columns]).map(&:to_s)
          result[:deal_table_hidden_columns] = arr.first(100)
        end
        if raw.key?(:deal_cards_hidden_fields)
          arr = Array(raw[:deal_cards_hidden_fields]).map(&:to_s)
          result[:deal_cards_hidden_fields] = arr.first(100)
        end

        # Last-picked view mode on the leads page. Restored on next visit so a
        # rep who prefers Kanban doesn't have to switch every time they log in.
        if raw.key?(:crm_leads_view_mode)
          mode = raw[:crm_leads_view_mode].to_s
          result[:crm_leads_view_mode] = mode if %w[table cards kanban].include?(mode)
        end

        # Per-user list of column keys hidden from the Inventory Stock List
        # report. Column keys are stable, defined in StockListReport.tsx; not
        # allowlisted because the set may grow over time.
        if raw.key?(:stock_list_hidden_columns)
          arr = Array(raw[:stock_list_hidden_columns]).map(&:to_s)
          result[:stock_list_hidden_columns] = arr.first(100)
        end

        # Saved multi-select status filter on the stock list report (vehicle
        # status keys). Same array-of-strings shape as the hidden-columns pref.
        if raw.key?(:stock_list_status_filter)
          arr = Array(raw[:stock_list_status_filter]).map(&:to_s)
          result[:stock_list_status_filter] = arr.first(50)
        end

        result
      end

      # Coerces and constrains calendar_preferences input. Mirrors
      # sanitize_workqueue_preferences — users can't store arbitrary data.
      def sanitize_calendar_preferences(raw)
        raw = raw.to_unsafe_h if raw.respond_to?(:to_unsafe_h)
        raw = raw.symbolize_keys

        result = {}

        if raw.key?(:default_view)
          view = raw[:default_view].to_s
          result[:default_view] = view if %w[my team service_all service_unassigned all].include?(view)
        end

        # Empty array = show all types (matches the events endpoint contract).
        if raw.key?(:default_types)
          types = Array(raw[:default_types]).map(&:to_s)
          result[:default_types] = types & %w[task meeting call reminder service_ticket]
        end

        %i[hide_completed hide_past].each do |key|
          result[key] = ActiveModel::Type::Boolean.new.cast(raw[key]) if raw.key?(key)
        end

        # Date window around "today" that the calendar loads. days_back: 0 is
        # valid ("don't load the past"); clamp both to a year.
        %i[days_back days_forward].each do |key|
          next unless raw.key?(key)
          result[key] = raw[key].to_i.clamp(0, 365)
        end

        result
      end

      def authenticate_any_user
        # Try to get token from Authorization header
        header = request.headers['Authorization']
        
        unless header.present?
          render json: {
            success: false,
            error: 'Unauthorized - Missing authorization header'
          }, status: :unauthorized
          return
        end

        token = header.split(' ').last
        decoded = JsonWebToken.decode(token)

        unless decoded
          render json: {
            success: false,
            error: 'Unauthorized - Invalid or expired token'
          }, status: :unauthorized
          return
        end

        # Set user ID based on token type
        if decoded[:user_id]
          @current_user_id = decoded[:user_id]
          @current_company_id = decoded[:company_id]

          # Check for impersonation header (platform admins only)
          resolve_impersonation
        elsif decoded[:buyer_portal_access_id]
          @current_portal_buyer_id = decoded[:buyer_portal_access_id]
        else
          render json: {
            success: false,
            error: 'Unauthorized - Invalid token format'
          }, status: :unauthorized
          return
        end
      end

      # Override to use cached ID, with impersonation support
      def current_user
        return @current_user if @current_user.present?
        if @impersonated_user
          @current_user = @impersonated_user
        else
          @current_user = @current_user_id ? User.find_by(id: @current_user_id) : nil
        end
      end

      # Override to use cached ID
      def current_portal_buyer
        return @current_portal_buyer if @current_portal_buyer.present?
        @current_portal_buyer = @current_portal_buyer_id ? BuyerPortalAccess.find_by(id: @current_portal_buyer_id) : nil
      end

      def set_user
        # Determine if this is a portal user or company user
        if current_portal_buyer
          @user = current_portal_buyer
          @user_type = 'client'
        else
          @user = current_user
          @user_type = 'admin'
        end

        unless @user
          render json: {
            success: false,
            error: 'Unauthorized'
          }, status: :unauthorized
          return
        end
      end

      def extract_first_name
        if @user_type == 'client' && @user.buyer.respond_to?(:first_name)
          @user.buyer.first_name
        elsif @user.respond_to?(:first_name)
          @user.first_name
        end
      end

      def extract_last_name
        if @user_type == 'client' && @user.buyer.respond_to?(:last_name)
          @user.buyer.last_name
        elsif @user.respond_to?(:last_name)
          @user.last_name
        end
      end

      def extract_phone
        if @user_type == 'client' && @user.buyer.respond_to?(:phone)
          @user.buyer.phone
        elsif @user.respond_to?(:phone)
          @user.phone
        end
      end

      def extract_address
        if @user_type == 'client' && @user.buyer.respond_to?(:address)
          @user.buyer.address
        end
      end

      def extract_city
        if @user_type == 'client' && @user.buyer.respond_to?(:city)
          @user.buyer.city
        end
      end

      def extract_state
        if @user_type == 'client' && @user.buyer.respond_to?(:state)
          @user.buyer.state
        end
      end

      def extract_zip
        if @user_type == 'client' && @user.buyer.respond_to?(:zip)
          @user.buyer.zip
        end
      end

      def log_password_change
        Rails.logger.info({
          event: 'password_changed',
          user_id: @user.id,
          user_type: @user_type,
          ip_address: request.remote_ip,
          timestamp: Time.current
        }.to_json)
      end

      def log_mfa_change(enabled)
        Rails.logger.info({
          event: 'mfa_settings_changed',
          user_id: @user.id,
          user_type: @user_type,
          mfa_enabled: enabled,
          mfa_method: @user.mfa_method,
          ip_address: request.remote_ip,
          timestamp: Time.current
        }.to_json)
      end
    end
  end
end
