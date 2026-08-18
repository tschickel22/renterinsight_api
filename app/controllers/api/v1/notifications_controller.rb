# app/controllers/api/v1/notifications_controller.rb
class Api::V1::NotificationsController < ApplicationController
  before_action :set_company_scope
  before_action :set_notification, only: [:show, :mark_as_read, :mark_as_unread, :destroy, :download_attachment]
  
  def index
    # Skip RBAC for now - all authenticated users can see their own notifications
    # return unless authorize_action!('notifications', 'read')
    
    # Base query - only current user's notifications
    # Platform admins see ALL their notifications regardless of company view
    if current_user.platform_admin?
      @notifications = current_user.notifications.recent
    else
      @notifications = current_user.notifications.where(company_id: @company.id).recent
    end
    
    # Apply filters
    @notifications = @notifications.unread if params[:unread_only] == 'true'
    @notifications = @notifications.by_category(params[:category]) if params[:category].present?
    @notifications = @notifications.by_type(params[:notification_type]) if params[:notification_type].present?
    
    # Pagination
    page = params[:page]&.to_i || 1
    per_page = params[:per_page]&.to_i || 25
    per_page = [per_page, 100].min # Max 100 per page
    
    total = @notifications.count
    @notifications = @notifications.offset((page - 1) * per_page).limit(per_page)
    
    # Get unread count
    # Platform admins see ALL their notifications regardless of company view
    if current_user.platform_admin?
      unread_count = current_user.notifications.unread.count
    else
      unread_count = current_user.notifications.where(company_id: @company.id).unread.count
    end
    
    render json: {
      notifications: @notifications.map(&:as_json_with_details),
      pagination: {
        page: page,
        per_page: per_page,
        total: total,
        pages: (total.to_f / per_page).ceil
      },
      unread_count: unread_count
    }
  end
  
  def show
    # Skip RBAC for now - all authenticated users can see their own notifications
    # return unless authorize_action!('notifications', 'read')
    
    render json: @notification.as_json_with_details
  end
  
  def unread_count
    # Skip RBAC for now - all authenticated users can see their own notifications
    # TODO: Add 'notifications' resource to RBAC system
    # return unless authorize_action!('notifications', 'read')
    
    # Platform admins see ALL their notifications regardless of company view
    if current_user.platform_admin?
      count = current_user.notifications.unread.count
    else
      count = current_user.notifications.where(company_id: @company.id).unread.count
    end
    
    render json: { unread_count: count }
  end
  
  def mark_as_read
    # Skip RBAC for now
    # return unless authorize_action!('notifications', 'update')
    
    @notification.mark_as_read!
    
    render json: @notification.as_json_with_details
  end
  
  def mark_as_unread
    # Skip RBAC for now
    # return unless authorize_action!('notifications', 'update')
    
    @notification.mark_as_unread!
    
    render json: @notification.as_json_with_details
  end
  
  def mark_all_read
    # Skip RBAC for now
    # return unless authorize_action!('notifications', 'update')
    
    # Platform admins mark ALL their notifications as read
    if current_user.platform_admin?
      current_user.notifications.unread.update_all(
        read: true,
        read_at: Time.current
      )
    else
      current_user.notifications.where(company_id: @company.id).unread.update_all(
        read: true,
        read_at: Time.current
      )
    end
    
    render json: { success: true, message: 'All notifications marked as read' }
  end
  
  def destroy
    # Skip RBAC for now
    # return unless authorize_action!('notifications', 'delete')

    @notification.destroy

    render json: { success: true, message: 'Notification deleted' }
  end

  # Bulk delete notifications for current_user. Two modes:
  #   - { ids: [1,2,3] }                          → delete just those ids
  #   - { all: true, filters: { ... } }           → delete every notification
  #                                                 matching the current view's
  #                                                 filters (unread_only,
  #                                                 category, notification_type)
  # Always goes through base_scope so users can never touch records that
  # don't belong to them. Uses delete_all for performance; Notification has
  # no destroy callbacks (just ActiveStorage attachments, which become
  # orphan blobs — acceptable for the notification-purge use case).
  def bulk_destroy
    scope = base_scope
    if ActiveModel::Type::Boolean.new.cast(params[:all])
      scope = apply_bulk_filters(scope, params[:filters])
      deleted = scope.delete_all
    else
      ids = Array(params[:ids]).map(&:to_i).reject(&:zero?)
      return render(json: { error: 'No ids' }, status: :bad_request) if ids.empty?
      deleted = scope.where(id: ids).delete_all
    end
    render json: { deleted: deleted, message: "Deleted #{deleted} notifications" }
  end

  # Bulk mark-as-read for current_user. Two modes:
  #   - { ids: [...] }                            → mark just those ids
  #   - { all: true, filters: { ... } }           → mark every unread
  #                                                 notification matching the
  #                                                 current view's filters
  # Always restricts to unread rows so the returned `marked` count reflects
  # rows that actually changed (idempotent re-runs return 0).
  def bulk_mark_read
    scope = base_scope.unread
    if ActiveModel::Type::Boolean.new.cast(params[:all])
      scope = apply_bulk_filters(scope, params[:filters])
      marked = scope.update_all(read: true, read_at: Time.current)
    else
      ids = Array(params[:ids]).map(&:to_i).reject(&:zero?)
      return render(json: { error: 'No ids' }, status: :bad_request) if ids.empty?
      marked = scope.where(id: ids).update_all(read: true, read_at: Time.current)
    end
    render json: { marked: marked, message: "Marked #{marked} as read" }
  end

  def broadcast
    # Skip RBAC for now, but still check admin
    # return unless authorize_action!('notifications', 'create')
    
    # Only admins can broadcast
    unless current_user.effective_admin?
      return render json: { error: 'Unauthorized' }, status: :forbidden
    end
    
    message = params[:message]
    user_ids = params[:user_ids]  # NEW: Accept specific user IDs
    location_ids = params[:location_ids]
    roles = params[:roles]
    send_email = ActiveModel::Type::Boolean.new.cast(params[:send_email])
    send_sms = ActiveModel::Type::Boolean.new.cast(params[:send_sms])
    send_push = ActiveModel::Type::Boolean.new.cast(params[:send_push])
    attachments = params[:attachments] || []  # NEW: Accept file uploads

    # Log what we received
    Rails.logger.info "[Broadcast] Delivery options: send_email=#{send_email.inspect}, send_sms=#{send_sms.inspect}, send_push=#{send_push.inspect}"
    Rails.logger.info "[Broadcast] Raw params: send_email='#{params[:send_email]}', send_sms='#{params[:send_sms]}'"
    
    if message.blank?
      return render json: { error: 'Message is required' }, status: :unprocessable_entity
    end
    
    if message.length < 10
      return render json: { error: 'Message must be at least 10 characters' }, status: :unprocessable_entity
    end
    
    if message.length > 500
      return render json: { error: 'Message must be less than 500 characters' }, status: :unprocessable_entity
    end
    
    # If specific user IDs provided, use those instead of location/role filtering
    if user_ids.present?
      # Send to specific users
      users = User.where(id: user_ids, deleted_at: nil)
      
      sent_count = 0
      users.find_each do |user|
        notification = NotificationService.create(
          recipient: user,
          notification_type: :broadcast_message,
          message: message,
          deliver_now: false,
          company_id: @company.id,
          actor: current_user,
          attachments: attachments,  # Pass attachments
          # Broadcast push is the admin's explicit choice below, not the
          # per-user preference default.
          push: false
        )

        if notification
          # Override preference for broadcast delivery channels
          if send_email || send_sms || send_push
            NotificationService.deliver_broadcast(notification, send_email: send_email, send_sms: send_sms, send_push: send_push)
          end

          sent_count += 1
        end
      end
      
      render json: {
        success: true,
        sent_count: sent_count,
        message: "Broadcast sent to #{sent_count} user(s)"
      }
    else
      # Use original location/role filtering
      result = NotificationService.broadcast(
        message: message,
        location_ids: location_ids,
        roles: roles,
        send_email: send_email,
        send_sms: send_sms,
        send_push: send_push,
        deliver_now: true,
        actor: current_user,
        attachments: attachments  # Pass attachments
      )
      
      render json: {
        success: result[:success],
        sent_count: result[:sent_count],
        message: "Broadcast sent to #{result[:sent_count]} user(s)"
      }
    end
  end
  
  def preview_recipients
    # Only admins can preview
    unless current_user.effective_admin?
      return render json: { error: 'Unauthorized' }, status: :forbidden
    end
    
    location_ids = params[:location_ids]
    roles = params[:roles]
    
    # Get company_id from Current context
    company_id = @company.id
    
    # Find all matching users (same logic as broadcast)
    users = User.where(company_id: company_id, deleted_at: nil)
    
    # Track cross-company admins
    cross_company_admin_ids = []
    
    # Filter by locations if specified
    if location_ids.present?
      user_ids = UserLocation.where(location_id: location_ids).pluck(:user_id)
      
      # Include platform admins from ANY company
      cross_company_admin_ids = User.where(deleted_at: nil)
                                   .where(role: ['platform_admin', 'super_admin'])
                                   .where.not(company_id: company_id)
                                   .pluck(:id)
      
      # Company-specific admins
      company_admin_ids = User.where(company_id: company_id, deleted_at: nil)
                             .where(role: ['admin', 'company_admin'])
                             .pluck(:id)
      
      combined_user_ids = (user_ids + company_admin_ids).uniq
      users = users.where(id: combined_user_ids)
    end
    
    # Filter by roles if specified
    if roles.present?
      role_ids = Role.where(key: roles).pluck(:id)
      user_ids = UserRoleAssignment.where(role_id: role_ids).pluck(:user_id)
      users = users.where(id: user_ids)
    end
    
    # Add cross-company platform admins
    if cross_company_admin_ids.any?
      cross_company_admins = User.where(id: cross_company_admin_ids, deleted_at: nil)
      all_user_ids = users.pluck(:id) + cross_company_admin_ids
      users = User.where(id: all_user_ids.uniq, deleted_at: nil)
    end
    
    # Eager load associations to avoid N+1
    users = users.includes(:user_role_assignments => :role, :user_locations => :location)
    
    # Build recipient list with details
    recipients = users.map do |user|
      # Get role display name from RBAC if available, otherwise use legacy role
      role_display = begin
        # Check if company uses RBAC and user has role assignments
        if @company.rbac_enabled? && user.user_role_assignments.any?
          # Get primary role (first one, or highest priority)
          primary_assignment = user.user_role_assignments
                                  .select { |ura| ura.role.present? }
                                  .sort_by { |ura| [ura.role.is_system_role? ? 0 : 1, ura.role.id] }
                                  .first
          primary_assignment&.role&.display_name || user.role&.titleize || 'User'
        else
          # Legacy role field
          user.role&.titleize || 'User'
        end
      rescue => e
        Rails.logger.error("Error getting role for user #{user.id}: #{e.message}")
        user.role&.titleize || 'User'
      end
      
      # Get location names safely
      location_names = begin
        if user.respond_to?(:user_locations)
          user.user_locations.map { |ul| ul.location&.name }.compact
        else
          []
        end
      rescue => e
        Rails.logger.error("Error getting locations for user #{user.id}: #{e.message}")
        []
      end
      
      {
        id: user.id,
        name: "#{user.first_name} #{user.last_name}".strip.presence || user.email,
        email: user.email,
        phone: user.phone,
        role: role_display,
        locations: location_names
      }
    end
    
    render json: {
      count: recipients.length,
      recipients: recipients
    }
  rescue => e
    Rails.logger.error("Error in preview_recipients: #{e.message}")
    Rails.logger.error(e.backtrace.first(10).join("\n"))
    render json: { error: "Failed to load recipients: #{e.message}" }, status: :internal_server_error
  end
  
  def stats
    # Skip RBAC for now
    # return unless authorize_action!('notifications', 'read')
    
    # Platform admins see ALL their notifications regardless of company view
    if current_user.platform_admin?
      notifications = current_user.notifications
    else
      notifications = current_user.notifications.where(company_id: @company.id)
    end
    
    render json: {
      total: notifications.count,
      unread: notifications.unread.count,
      by_category: Notification::TYPES.values.map { |t| t[:category] }.uniq.map do |category|
        {
          category: category,
          total: notifications.by_category(category).count,
          unread: notifications.by_category(category).unread.count
        }
      end
    }
  end
  
  def test
    # Send a test notification to the current user
    notification = NotificationService.create(
      recipient: current_user,
      notification_type: :broadcast_message,
      message: 'This is a test notification to verify your notification settings are working correctly. If you received this via email and/or SMS, those channels are configured properly!',
      deliver_now: true,
      title: 'Test Notification',
      priority: 'normal',
      category: 'system',
      action_url: '/account/settings?tab=notifications',
      action_text: 'View Settings'
    )
    
    if notification
      render json: {
        success: true,
        message: 'Test notification sent',
        notification: notification.as_json_with_details
      }
    else
      render json: {
        success: false,
        error: 'Failed to send test notification'
      }, status: :unprocessable_entity
    end
  end
  
  # Download attachment from notification
  def download_attachment
    # Find the attachment
    attachment = @notification.attachments.find_by(id: params[:attachment_id])
    
    unless attachment
      return render json: { error: 'Attachment not found' }, status: :not_found
    end
    
    # Send the file
    send_data attachment.download,
      filename: attachment.filename.to_s,
      type: attachment.content_type,
      disposition: 'attachment'
  rescue => e
    Rails.logger.error("Error downloading attachment: #{e.message}")
    render json: { error: 'Failed to download attachment' }, status: :internal_server_error
  end
  
  private
  
  def set_notification
    # Platform admins can access ALL their notifications
    if current_user.platform_admin?
      @notification = current_user.notifications.find(params[:id])
    else
      @notification = current_user.notifications.where(company_id: @company.id).find(params[:id])
    end
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Notification not found' }, status: :not_found
  end

  # Notifications belonging to current_user. Platform admins see every
  # notification regardless of the active-company view; everyone else is
  # scoped to the company the request is set against. Mirrors the
  # platform_admin pattern in index / mark_all_read.
  def base_scope
    if current_user.platform_admin?
      current_user.notifications
    else
      current_user.notifications.where(company_id: @company.id)
    end
  end

  # Applies the same filters the index view honors so the all-pages bulk
  # actions act on exactly the rows the user sees. Shape mirrors what the
  # FE sends from NotificationCenter.currentFilters().
  def apply_bulk_filters(scope, filters)
    return scope if filters.blank?
    filters = filters.to_unsafe_h if filters.respond_to?(:to_unsafe_h)
    scope = scope.unread                                       if ActiveModel::Type::Boolean.new.cast(filters['unread_only'])
    scope = scope.by_category(filters['category'])             if filters['category'].present?
    scope = scope.by_type(filters['notification_type'])        if filters['notification_type'].present?
    scope
  end
end
