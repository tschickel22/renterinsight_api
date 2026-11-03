# frozen_string_literal: true

module Api
  module Companies
    class UsersController < ApplicationController
      include RoleAssignmentRules

      before_action :authenticate_user!
      before_action :set_company_and_verify_access
      before_action :set_user, only: [:show, :update, :destroy, :restore, :resend_invitation, :other_logins]
      
      # GET /api/companies/:company_id/users
      def index
        users = @company.users
        users = users.where(deleted_at: nil) unless ActiveModel::Type::Boolean.new.cast(params[:include_deleted])

        render json: {
          success: true,
          users: users.map { |user| serialize_user(user) }
        }
      end
      
      # GET /api/companies/:company_id/users/available_roles
      def available_roles
        # Get current user's role level
        current_level = ROLE_HIERARCHY[current_user.role] || 0
        
        # Check RBAC roles if the user has them
        if @company&.use_rbac_system
          current_user.roles_for_company(@company.id).each do |role|
            role_level = ROLE_HIERARCHY[role.key] || ROLE_HIERARCHY[role.name] || 0
            current_level = [current_level, role_level].max
          end
        end
        
        # Platform admins and super admins can assign any role
        if current_user.platform_admin? || current_user.super_admin?
          current_level = 100
        end
        
        # The shared system roles plus this company's own. Another company's custom
        # roles, and their names, are none of this company's business.
        all_roles = Role.where(company_id: [nil, @company.id], tier: ['company', 'location'], active: true).map do |role|
          {
            key: role.key,
            name: role.name,
            hierarchy_level: ROLE_HIERARCHY[role.key] || ROLE_HIERARCHY[role.name] || 0,
            active: role.active  # ✅ Include active field
          }
        end
        
        # Filter roles: user can only assign roles below their own level, plus
        # company admins can make another company admin (grantable_level?)
        # For system roles (hierarchy_level > 0): check hierarchy
        # For custom roles (hierarchy_level == 0): include if user is admin-level or higher
        available = all_roles.select { |role|
          if role[:hierarchy_level] > 0
            # System role - check hierarchy
            grantable_level?(current_level, role[:hierarchy_level])
          else
            # Custom role - include if user is admin or higher (level >= 40)
            current_level >= 40
          end
        }
        
        render json: {
          success: true,
          roles: available
        }
      end
      
      # GET /api/companies/:company_id/users/:id
      def show
        render json: {
          success: true,
          user: serialize_user(@user)
        }
      end
      
      # GET /api/companies/:company_id/users/:id/other_logins
      # The other companies this person works in. Platform team only: it shows
      # another company's data, which a dealer's admin must not see.
      def other_logins
        unless current_user.platform_admin? || current_user.super_admin?
          return render json: { success: false, error: 'You do not have permission to see this.' }, status: :forbidden
        end

        root = @user.sign_in_account
        others = ::User.where(id: root.id).or(::User.where(primary_user_id: root.id))
                       .where(deleted_at: nil).where.not(id: @user.id).includes(:company).order(:id)
        render json: {
          success: true,
          logins: others.map do |u|
            role = u.user_role_assignments.where(company_id: u.company_id).includes(:role).order(:id).first&.role
            { user_id: u.id, company_name: u.company&.name, role: role&.name || u.role, status: u.status }
          end
        }
      end

      # POST /api/companies/:company_id/users/bulk-invite
      # { people: [{ email, name }], role, match_existing_roles }
      def bulk_invite
        people = Array(params[:people]).map { |p| p.permit(:email, :name).to_h.symbolize_keys }
        return render(json: { success: false, error: 'Add at least one person' }, status: :unprocessable_entity) if people.empty?

        if people.length > BulkInviteService::MAX_PEOPLE
          return render(json: { success: false, error: "Add up to #{BulkInviteService::MAX_PEOPLE} people at a time" }, status: :unprocessable_entity)
        end

        platform_admin = current_user.platform_admin? || current_user.super_admin?
        match_roles = ActiveModel::Type::Boolean.new.cast(params[:match_existing_roles]) || false
        # Matching reads the person's role in another company, so it stays with
        # the platform team. A dealer's admin must not learn it from an invite.
        # It exists for linked accounts into an installer company, nothing else.
        if match_roles && !(platform_admin && @company.industry == 'installer')
          return render(json: { success: false, error: 'Keeping a current role is only for linked accounts into an installer company.' }, status: :forbidden)
        end

        role = params[:role].presence
        if role && !can_assign_role?(role)
          return render(json: { success: false, error: 'You do not have permission to assign this role.' }, status: :forbidden)
        end
        if role.nil? && !match_roles
          return render(json: { success: false, error: 'Choose a role' }, status: :unprocessable_entity)
        end

        rows = BulkInviteService.new(invited_by: current_user, company: @company, default_role: role, match_roles: match_roles).call(people)
        rows = rows.map { |r| r.except(:existing_login) } unless platform_admin
        render json: { success: true, results: rows, invited: rows.count { |r| r[:status] == 'invited' } }
      end

      # POST /api/companies/:company_id/users
      def create
        # SECURITY: Enforce role hierarchy (RoleAssignmentRules)
        requested_role = params[:role] || 'staff'
        unless can_assign_role?(requested_role)
          Rails.logger.warn "🚫 [SECURITY] User #{current_user.id} (#{current_user.role}) attempted to create user with role '#{requested_role}' without sufficient privileges"
          return render json: {
            success: false,
            error: 'You do not have permission to assign this role.'
          }, status: :forbidden
        end
        
        # A deleted person keeps their email, so inviting it again would attach
        # the invitation to an account nobody can sign in to.
        if params[:email].present? && @company.users.where.not(deleted_at: nil).where('LOWER(email) = ?', params[:email].to_s.strip.downcase).exists?
          return render json: {
            success: false,
            error: 'This email belongs to a deleted user. Turn on Include deleted users in the filters and restore them.'
          }, status: :unprocessable_entity
        end

        service = InvitationService.new(
          invited_by: current_user,
          company: @company
        )
        
        recipient_name = params[:recipient_name] || params[:recipientName]
        delivery_method = params[:deliveryMethod] || params[:delivery_method] || 'email'
        
        # Extract location params (support both camelCase and snake_case)
        location_ids = params[:location_ids] || params[:locationIds] || []
        location_role = params[:location_role] || params[:locationRole]
        
        Rails.logger.info "📨 [Companies::UsersController] Creating invitation"
        Rails.logger.info "📨 [Companies::UsersController] email: #{params[:email]}"
        Rails.logger.info "📨 [Companies::UsersController] role: #{params[:role]}"
        Rails.logger.info "📨 [Companies::UsersController] location_ids: #{location_ids.inspect}"
        Rails.logger.info "📨 [Companies::UsersController] location_role: #{location_role}"
        Rails.logger.info "📨 [Companies::UsersController] company: #{@company.id} (#{@company.name})"
        
        result = service.create_invitation(
          invitation_type: 'company_user',
          email: params[:email],
          phone: params[:phone],
          recipient_name: recipient_name,
          role: params[:role] || 'staff',
          permissions: params[:permissions] || [],
          delivery_method: delivery_method,
          message: params[:message],
          location_ids: location_ids,
          location_role: location_role,
          recipient_data: {
            email_template_id: params[:emailTemplateId] || params[:email_template_id],
            sms_template_id: params[:smsTemplateId] || params[:sms_template_id]
          }.compact.stringify_keys
        )
        
        if result[:success]
          invitation = result[:invitation]
          @user = @company.users.find_by(email: invitation.email)
          
          render json: {
            success: true,
            invitation: serialize_invitation(invitation),
            user: @user ? serialize_user(@user) : serialize_invitation(invitation),
            message: result[:message]
          }, status: :created
        else
          render json: { 
            success: false,
            error: result[:error]
          }, status: :unprocessable_entity
        end
      end
      
      # PATCH/PUT /api/companies/:company_id/users/:id
      def update
        unless @user.id == current_user.id || can?('users', 'update')
          return render json: { success: false, error: 'You do not have permission to edit users.' }, status: :forbidden
        end
        return refuse_higher_user('edit') if outranks_current_user?(@user)

        # An empty list clears them (All Locations); no key leaves them alone.
        # Refused out loud: a location change that quietly did nothing was the bug.
        change_locations = params.key?(:location_ids)
        if change_locations && !can?('users', 'update')
          return render json: { success: false, error: 'You do not have permission to change user locations.' }, status: :forbidden
        end

        # SECURITY: Prevent self-privilege escalation
        new_role = params[:user][:role] || params[:role]
        role_changed = new_role.present? && new_role != @user.role
        
        if role_changed && @user.id == current_user.id
          Rails.logger.warn "🚫 [SECURITY] User #{current_user.id} attempted to change their own role from '#{@user.role}' to '#{new_role}'"
          return render json: {
            success: false,
            error: 'You cannot change your own role. Please contact an administrator.'
          }, status: :forbidden
        end
        
        # SECURITY: Enforce role hierarchy (RoleAssignmentRules)
        if role_changed && !can_assign_role?(new_role)
          Rails.logger.warn "🚫 [SECURITY] User #{current_user.id} (#{current_user.role}) attempted to assign role '#{new_role}' without sufficient privileges"
          return render json: {
            success: false,
            error: 'You do not have permission to assign this role.'
          }, status: :forbidden
        end
        
        saved = ::User.transaction do
          @user.update(user_params).tap do |ok|
            sync_locations(Array(params[:location_ids]), params[:location_role]) if ok && change_locations
          end
        end

        if saved
          # If role changed, update RBAC assignment
          if role_changed && @company.use_rbac_system
            @user.replace_rbac_role(
              new_role,
              company_id: @company.id,
              assigned_by: current_user
            )
            Rails.logger.info "✅ [UsersController] Updated RBAC role to '#{new_role}' for user #{@user.id}"
          end
          
          render json: {
            success: true,
            user: serialize_user(@user),
            message: 'User updated successfully'
          }
        else
          render json: { 
            success: false,
            errors: @user.errors.full_messages,
            error: @user.errors.full_messages.join(', ')
          }, status: :unprocessable_entity
        end
      end
      
      # DELETE /api/companies/:company_id/users/:id
      def destroy
        return unless authorize_action!('users', 'delete')

        reason = params[:reason] || 'No reason provided'

        if @user.id == current_user.id
          return render json: { success: false, error: 'You cannot delete your own account.' }, status: :forbidden
        end
        return refuse_higher_user('delete') if outranks_current_user?(@user)

        if @user.soft_delete
          Rails.logger.info "[Companies::UsersController] User #{@user.id} deleted by #{current_user.id}: #{reason}"
          render json: {
            success: true,
            message: 'User deleted successfully',
            reason: reason
          }, status: :ok
        else
          render json: { 
            success: false,
            errors: @user.errors.full_messages,
            error: @user.errors.full_messages.join(', ')
          }, status: :unprocessable_entity
        end
      end
      
      # POST /api/companies/:company_id/users/:id/restore
      def restore
        return unless authorize_action!('users', 'delete')
        return refuse_higher_user('restore') if outranks_current_user?(@user)

        if @user.restore_deleted
          Rails.logger.info "[Companies::UsersController] User #{@user.id} restored by #{current_user.id}: #{params[:reason]}"
          render json: { success: true, user: serialize_user(@user), message: 'User restored successfully' }
        else
          render json: { success: false, errors: @user.errors.full_messages, error: @user.errors.full_messages.join(', ') }, status: :unprocessable_entity
        end
      end

      # POST /api/companies/:company_id/users/:id/resend_invitation
      def resend_invitation
        # For users with 'invited' status, create a new invitation
        # (old invitation was already used to create placeholder user)

        # Accepting an invitation sets a password, so it must not be a way back
        # in for someone an admin shut out.
        if @user.deactivated?
          return render json: { success: false, error: 'This person is disabled. Set them back to Active before inviting them.' },
                        status: :unprocessable_entity
        end

        service = InvitationService.new(
          invited_by: current_user,
          company: @company
        )
        
        # Get user's location assignments to preserve in new invitation
        location_ids = @user.user_locations.where(active: true).pluck(:location_id)
        location_role = @user.user_locations.where(active: true).first&.location_role
        
        # Create a new invitation (the old one was consumed when placeholder user was created)
        result = service.create_invitation(
          invitation_type: 'company_user',
          email: @user.email,
          phone: @user.phone,
          recipient_name: @user.name || [@user.first_name, @user.last_name].compact.join(' '),
          role: @user.role,
          permissions: @user.permissions || [],
          delivery_method: params[:deliveryMethod] || 'email',
          message: params[:message],
          location_ids: location_ids,
          location_role: location_role
        )
        
        if result[:success]
          render json: { 
            success: true,
            message: 'Invitation resent successfully',
            user: serialize_user(@user.reload),
            invitation: serialize_invitation(result[:invitation])
          }
        else
          render json: { 
            success: false,
            error: result[:error]
          }, status: :unprocessable_entity
        end
      rescue => e
        Rails.logger.error "Error in resend_invitation: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        
        render json: { 
          success: false,
          error: 'Failed to resend invitation',
          details: e.message
        }, status: :internal_server_error
      end
      
      # GET /api/companies/:company_id/users/pending-invitations
      # Returns the users who have not yet accepted/logged in — i.e. who would
      # receive an invite from the "resend all" action. Covers imported users
      # (status 'active' but Never logged in) and genuinely invited users.
      def pending_invitations
        targets = pending_invitation_users
        render json: {
          success: true,
          count: targets.size,
          users: targets.map { |u| serialize_user(u) }
        }
      end
      
      # POST /api/companies/:company_id/users/resend-all-invitations
      # Sends (or resends) the standard email invitation to every user who has
      # not yet logged in. Uses the SAME InvitationService path as the initial
      # invite, so the email is identical. Idempotent and safe to press again.
      def resend_all_invitations
        targets = pending_invitation_users
        
        if targets.empty?
          return render json: {
            success: true,
            message: 'No pending users to invite.',
            sent: 0,
            failed: 0,
            results: []
          }
        end
        
        service = InvitationService.new(invited_by: current_user, company: @company)
        sent = 0
        failed = 0
        results = []
        
        targets.each do |user|
          begin
            location_ids = user.user_locations.where(active: true).pluck(:location_id)
            location_role = user.user_locations.where(active: true).first&.location_role
            recipient_name = user.name.presence || [user.first_name, user.last_name].compact.join(' ')
            
            result = service.create_invitation(
              invitation_type: 'company_user',
              email: user.email,
              phone: user.phone,
              recipient_name: recipient_name,
              role: user.role,
              permissions: user.permissions || [],
              delivery_method: 'email',
              location_ids: location_ids,
              location_role: location_role
            )
            
            if result[:success]
              sent += 1
              results << { email: user.email, success: true }
            else
              failed += 1
              results << { email: user.email, success: false, error: result[:error] }
            end
          rescue => e
            failed += 1
            results << { email: user.email, success: false, error: e.message }
            Rails.logger.error "[resend_all_invitations] #{user.email}: #{e.message}"
          end
        end
        
        render json: {
          success: true,
          message: "Sent #{sent} invitation#{'s' unless sent == 1}" + (failed.positive? ? ", #{failed} failed" : ''),
          sent: sent,
          failed: failed,
          results: results
        }
      rescue => e
        Rails.logger.error "Error in resend_all_invitations: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        render json: {
          success: false,
          error: 'Failed to send invitations',
          details: e.message
        }, status: :internal_server_error
      end
      
      private
      
      # Users who have NOT completed onboarding (never logged in) OR are flagged
      # 'invited'. Excludes the current user, platform/super admins, and deleted
      # users. This is the "pending" population for bulk invite — for imported
      # tenants every user is status 'active' with no login yet, so we key off
      # "has never logged in" rather than status alone.
      #
      # "Never logged in" must agree with how serialize_user computes last login:
      # it prefers a login_activities row, falling back to last_sign_in_at. So a
      # user counts as logged-in if EITHER exists; we exclude those here.
      def pending_invitation_users
        logged_in_user_ids = LoginActivity
                               .where(user_type: 'User', user_id: @company.users.select(:id))
                               .distinct
                               .pluck(:user_id)

        scope = @company.users.where(deleted_at: nil).where.not(status: User::DEACTIVATED_STATUSES)
        scope = scope.where("status = 'invited' OR (last_sign_in_at IS NULL AND id NOT IN (?))",
                            logged_in_user_ids.presence || [0])
        scope.reject do |u|
          u.id == current_user.id || u.platform_admin? || u.super_admin?
        end
      end
      
      def set_company_and_verify_access
        requested_company_id = params[:company_id]
        
        if current_user.platform_admin? || current_user.super_admin?
          @company = ::Company.find_by(id: requested_company_id)
          unless @company
            render json: { success: false, error: 'Company not found' }, status: :not_found
            return
          end
          Rails.logger.info "✅ [Companies::UsersController] Platform admin accessing company #{@company.id}"
        else
          unless current_user.company_id.to_s == requested_company_id.to_s
            Rails.logger.error "🚫 [Companies::UsersController] User #{current_user.id} attempted to access company #{requested_company_id} but belongs to #{current_user.company_id}"
            render json: { success: false, error: 'Forbidden - Cannot access other company users' }, status: :forbidden
            return
          end
          
          @company = ::Company.find_by(id: current_user.company_id)
          unless @company
            render json: { success: false, error: 'Company not found' }, status: :not_found
            return
          end
        end
      end
      
      def set_user
        @user = @company.users.find_by(id: params[:id])
        unless @user
          render json: { success: false, error: 'User not found' }, status: :not_found
        end
      end
      
      def user_params
        params.require(:user).permit(
          :email,
          :first_name,
          :last_name,
          :phone,
          :role,
          :status,
          :title,
          :department
        )
      end
      
      # Role hierarchy for permission checking
      # Higher number = higher privilege
      ROLE_HIERARCHY = {
        # Platform tier (100)
        'platform_admin' => 100,
        'super_admin' => 100,
        
        # Company Administrator tier (50)
        'Company Administrator' => 50,
        'company_admin' => 50,
        'admin' => 50,
        
        # Manager tier (40) - Operational control
        'Company Manager' => 40,
        'company_manager' => 40,
        'manager' => 40,
        'Location Administrator' => 40,
        'location_admin' => 40,
        
        # Staff tier (30) - Standard user access
        'Company Staff' => 30,
        'company_staff' => 30,
        'staff' => 30,
        'Location Manager' => 30,
        'location_manager' => 30,
        
        # Specialist tier (20) - Department-specific access
        'CRM Specialist' => 20,
        'crm_specialist' => 20,
        'Finance Staff' => 20,
        'finance_staff' => 20,
        'Inventory Manager' => 20,
        'inventory_manager' => 20,
        'Location Staff' => 20,
        'location_staff' => 20,
        'Sales Representative' => 20,
        'sales_rep' => 20,
        'Service Technician' => 20,
        'service_tech' => 20,
        
        # Read-Only tier (10) - View-only access
        'Read-Only User' => 10,
        'company_read_only' => 10,
        'read_only' => 10
      }.freeze
      
      # Peers may manage each other (a dealer with two admins needs that);
      # nobody may touch someone above them.
      def outranks_current_user?(user)
        return false if current_user.platform_admin? || current_user.super_admin? || user.id == current_user.id

        role_level_of(user) > role_level_of(current_user)
      end

      def refuse_higher_user(verb)
        render json: { success: false, error: "You cannot #{verb} someone with a higher role than yours." }, status: :forbidden
      end

      # Only this company's locations count. An existing row keeps its location
      # role; the role sent applies to rows being added.
      def sync_locations(location_ids, location_role)
        keep = @company.locations.where(id: location_ids).pluck(:id)
        @user.user_locations.where.not(location_id: keep).where(active: true).update_all(active: false, updated_at: Time.current)
        keep.each do |location_id|
          row = UserLocation.find_or_initialize_by(user_id: @user.id, location_id: location_id, company_id: @company.id)
          row.location_role ||= location_role.presence || 'location_staff'
          row.assigned_by ||= current_user.id.to_s
          row.active = true
          row.save!
        end
        # PermissionService keeps this for an hour, and the change must count now.
        Rails.cache.delete("permissions:#{@user.id}:accessible_locations")
      end
      
      def serialize_invitation(invitation)
        {
          id: invitation.id,
          invitationType: invitation.invitation_type,
          email: invitation.email,
          phone: invitation.phone,
          status: invitation.status,
          role: invitation.role,
          recipientName: invitation.recipient_name,
          deliveryMethod: invitation.delivery_method,
          message: invitation.message,
          sentAt: invitation.sent_at&.iso8601,
          expiresAt: invitation.expires_at&.iso8601,
          acceptedAt: invitation.accepted_at&.iso8601,
          lastSentAt: invitation.last_sent_at&.iso8601,
          resendCount: invitation.resend_count,
          attempts: invitation.attempts,
          viewedAt: invitation.viewed_at&.iso8601,
          canResend: invitation.can_accept?,
          canRevoke: invitation.status == 'pending',
          isExpired: invitation.expired?,
          daysUntilExpiry: invitation.expires_at ? ((invitation.expires_at - Time.current) / 1.day).round : 0,
          createdAt: invitation.created_at&.iso8601,
          updatedAt: invitation.updated_at&.iso8601,
          invitedBy: {
            id: invitation.invited_by.id,
            name: invitation.invited_by.name || invitation.invited_by.email,
            email: invitation.invited_by.email
          },
          company: invitation.company ? {
            id: invitation.company.id,
            name: invitation.company.name
          } : nil
        }
      end
      
      def serialize_user(user)
        # Get last login from login_activities
        last_login = nil
        if user.respond_to?(:login_activities)
          last_login = user.login_activities.order(logged_in_at: :desc).first
        end
        
        # Get MFA status from mfa_enabled field
        mfa_status = 'none'
        if user.respond_to?(:mfa_enabled) && user.mfa_enabled
          mfa_status = 'totp'
        end
        
        # Use the most recent of the two signals. last_sign_in_at is refreshed
        # on token refresh (active sessions), so it can be newer than the last
        # explicit login_activities row.
        last_login_time = [last_login&.logged_in_at, user.last_sign_in_at].compact.max
        
        result = {
          id: user.id,
          email: user.email,
          firstName: user.first_name,
          lastName: user.last_name,
          recipientName: [user.first_name, user.last_name].compact.join(' '),
          phone: user.phone,
          role: user.role || 'user',
          status: user.status || 'pending',
          title: user.title,
          department: user.department,
          
          # MFA Status (camelCase for frontend, boolean conversion)
          mfaEnabled: mfa_status != 'none',
          
          # Last Login (camelCase for frontend)
          lastLoginAt: last_login_time&.iso8601,
          
          # RBAC information (camelCase for frontend)
          rbacEnabled: @company&.use_rbac_system || false,
          permissions: build_permissions(user, @company),
          roles: build_roles(user, @company),
          
          invitationType: 'company_user',
          deliveryMethod: user.phone.present? ? 'both' : 'email',
          sentAt: user.created_at,
          lastSentAt: user.created_at,
          expiresAt: (user.created_at + 7.days).iso8601,
          resendCount: 0,
          acceptAttempts: 0,
          canResend: true,
          canRevoke: (user.status || 'pending') == 'pending',
          isExpired: false,
          daysUntilExpiry: 7,
          createdAt: user.created_at,
          updatedAt: user.updated_at
        }
        
        if current_user
          result[:invitedBy] = {
            id: current_user.id,
            name: [current_user.first_name, current_user.last_name].compact.join(' '),
            email: current_user.email
          }
        end
        
        if @company
          result[:company] = {
            id: @company.id,
            name: @company.name
          }
        end
        
        result[:deletedAt] = user.deleted_at if user.respond_to?(:deleted_at)
        
        result
      end
      
      # Build permissions array for frontend
      def build_permissions(user, company)
        return ['*:*:*'] if user.platform_admin? || user.super_admin?
        return ['*:*:*'] unless company&.use_rbac_system
        user.permissions_for_company(company.id)
      end
      
      # Build roles array for frontend
      def build_roles(user, company)
        return [{ key: 'platform_admin', name: 'Platform Admin', tier: 'platform' }] if user.platform_admin?
        return [{ key: 'super_admin', name: 'Super Admin', tier: 'platform' }] if user.super_admin?
        return [] unless company&.use_rbac_system
        
        user.roles_for_company(company.id).map do |role|
          {
            key: role.key,
            name: role.name,
            tier: role.tier,
            color: role.color
          }
        end
      end
    end
  end
end
