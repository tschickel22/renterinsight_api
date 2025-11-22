# frozen_string_literal: true

class InvitationService
  class Error < StandardError; end
  class InvitationNotFoundError < Error; end
  class InvitationExpiredError < Error; end
  class InvitationAlreadyAcceptedError < Error; end
  class TemplateNotFoundError < Error; end
  class DeliveryFailedError < Error; end
  
  def initialize(invited_by:, company: nil)
    @invited_by = invited_by
    @company = company
  end
  
  # Create and send a new invitation
  def create_invitation(
    invitation_type:,
    email:,
    phone: nil,
    recipient_name: nil,
    recipient_data: {},
    role: nil,
    permissions: [],
    delivery_method: 'email',
    message: nil,
    location_ids: [],
    location_role: nil
  )
    # Validate invitation type
    unless Invitation::INVITATION_TYPES.include?(invitation_type)
      raise Error, "Invalid invitation type: #{invitation_type}"
    end
    
    # Validate delivery method
    unless Invitation::DELIVERY_METHODS.include?(delivery_method)
      raise Error, "Invalid delivery method: #{delivery_method}"
    end
    
    # Normalize phone number if provided
    phone = PhoneNumberService.normalize(phone) if phone.present?
    
    # Validate phone number is required for SMS delivery
    if delivery_method.in?(['sms', 'both']) && phone.blank?
      raise Error, "Phone number is required for SMS delivery"
    end
    
    # Normalize location_ids to array of integers
    normalized_location_ids = normalize_location_ids(location_ids)
    
    # Validate location_ids belong to company
    if normalized_location_ids.any? && @company
      valid_location_ids = Location.where(id: normalized_location_ids, company_id: @company.id).pluck(:id)
      invalid_ids = normalized_location_ids - valid_location_ids
      if invalid_ids.any?
        raise Error, "Invalid location IDs: #{invalid_ids.join(', ')} - locations must belong to the company"
      end
      normalized_location_ids = valid_location_ids
    end
    
    # Create invitation record
    invitation, raw_token = Invitation.create_for_user(
      invitation_type: invitation_type,
      email: email,
      phone: phone,
      invited_by: @invited_by,
      company: @company,
      role: role,
      permissions: permissions,
      recipient_name: recipient_name,
      recipient_data: recipient_data,
      delivery_method: delivery_method,
      message: message,
      location_ids: normalized_location_ids,
      location_role: location_role
    )
    
    # Store raw token temporarily for sending
    invitation.token = raw_token
    
    # Create placeholder user with 'invited' status for company users
    if invitation_type == 'company_user'
      create_invited_user_placeholder(invitation, recipient_name)
    end
    
    # Send the invitation
    send_invitation(invitation, raw_token)
    
    {
      success: true,
      invitation: invitation,
      message: 'Invitation sent successfully'
    }
  rescue StandardError => e
    Rails.logger.error("Failed to create invitation: #{e.message}")
    Rails.logger.error(e.backtrace.first(5).join("\n"))
    
    {
      success: false,
      error: e.message
    }
  end
  
  # Send an existing invitation
  def send_invitation(invitation, raw_token = nil)
    # Get or find raw token
    raw_token ||= invitation.token
    unless raw_token
      raise Error, "Token is required to send invitation"
    end
    
    # Build context for template rendering (includes invitation URL)
    context = build_invitation_context(invitation, raw_token)
    
    # ALWAYS log invitation URL in development (before attempting to send)
    if Rails.env.development?
      log_invitation_url(invitation, context)
    end
    
    # Try to send via templates (optional in development)
    begin
      # Get appropriate template
      template = find_template(invitation)
      
      if template
        # Send via email if required
        if invitation.delivery_method.in?(['email', 'both'])
          send_email_invitation(invitation, template, context)
        end
        
        # Send via SMS if required
        if invitation.delivery_method.in?(['sms', 'both'])
          send_sms_invitation(invitation, template, context)
        end
      elsif Rails.env.production?
        # In production, templates are required
        raise TemplateNotFoundError, "No template found for #{invitation.invitation_type}"
      else
        # In development, log clearly and output to console
        error_msg = "⚠️  TEMPLATE MISSING: No #{invitation.delivery_method} template found for '#{invitation.invitation_type}'"
        Rails.logger.error error_msg
        puts "\n" + "="*80
        puts error_msg
        puts "Run: rails runner db/seeds/invitation_templates.rb"
        puts "Or: rails runner db/seeds/run_template_seed.rb"
        puts "="*80 + "\n"
      end
    rescue StandardError => e
      if Rails.env.production?
        # In production, fail hard
        Rails.logger.error("Failed to send invitation: #{e.message}")
        raise DeliveryFailedError, "Failed to send invitation: #{e.message}"
      else
        # In development, log clearly with details
        error_msg = "❌ INVITATION SEND FAILED (#{invitation.delivery_method}): #{e.class.name} - #{e.message}"
        Rails.logger.error error_msg
        Rails.logger.error e.backtrace.first(3).join("\n")
        puts "\n" + "="*80
        puts error_msg
        puts "Invitation Type: #{invitation.invitation_type}"
        puts "Delivery Method: #{invitation.delivery_method}"
        puts "Error: #{e.message}"
        puts "="*80 + "\n"
      end
    end
    
    # Update invitation status (even if sending failed in development)
    invitation.update!(
      sent_at: Time.current,
      last_sent_at: Time.current
    )
    
    true
  end
  
  # Verify an invitation token
  def verify_invitation(token)
    invitation = Invitation.find_valid_token(token)
    
    unless invitation
      raise InvitationNotFoundError, 'Invalid or expired invitation'
    end
    
    # Track that invitation was viewed
    invitation.update(viewed_at: Time.current) unless invitation.viewed_at
    
    {
      valid: true,
      invitation: invitation,
      context: invitation.template_context
    }
  end
  
  # Accept an invitation and create the user/access
  def accept_invitation(token:, user_params:, ip_address: nil, user_agent: nil)
    invitation = Invitation.find_valid_token(token)
    
    unless invitation
      raise InvitationNotFoundError, 'Invalid or expired invitation'
    end
    
    if invitation.accepted?
      raise InvitationAlreadyAcceptedError, 'Invitation has already been accepted'
    end
    
    if invitation.expired?
      raise InvitationExpiredError, 'Invitation has expired'
    end
    
    # Create user based on invitation type
    user = create_user_from_invitation(invitation, user_params)
    
    # Mark invitation as accepted
    invitation.mark_as_accepted!(ip_address: ip_address, user_agent: user_agent)
    
    {
      success: true,
      user: user,
      invitation: invitation
    }
  rescue StandardError => e
    invitation&.increment_attempts! if invitation
    
    Rails.logger.error("Failed to accept invitation: #{e.message}")
    
    {
      success: false,
      error: e.message
    }
  end
  
  # Resend an invitation
  def resend_invitation(invitation_id)
    invitation = Invitation.find(invitation_id)
    
    unless invitation.can_accept?
      raise Error, 'Invitation cannot be resent'
    end
    
    # Regenerate token for security
    raw_token = SecureRandom.urlsafe_base64(32)
    token_digest = Digest::SHA256.hexdigest(raw_token)
    
    invitation.update!(
      token_digest: token_digest,
      resend_count: invitation.resend_count + 1,
      last_sent_at: Time.current,
      expires_at: Invitation::TOKEN_EXPIRY.from_now # Reset expiry
    )
    
    invitation.token = raw_token
    send_invitation(invitation, raw_token)
    
    {
      success: true,
      invitation: invitation
    }
  end
  
  # Revoke an invitation
  def revoke_invitation(invitation_id, reason: nil)
    invitation = Invitation.find(invitation_id)
    invitation.revoke!(reason: reason)
    
    {
      success: true,
      invitation: invitation
    }
  end
  
  private
  
  # Log invitation URL to console (development only)
  def log_invitation_url(invitation, context)
    separator = "="*80
    
    Rails.logger.info "\n#{separator}"
    Rails.logger.info "🎉 INVITATION CREATED - #{invitation.invitation_type.upcase}"
    Rails.logger.info separator
    Rails.logger.info "Invitation ID: #{invitation.id}"
    Rails.logger.info "Email: #{invitation.email}"
    Rails.logger.info "Phone: #{invitation.phone || 'Not provided'}"
    Rails.logger.info "Recipient: #{invitation.recipient_name || 'Not provided'}"
    Rails.logger.info "Company: #{invitation.company&.name || 'N/A'}"
    Rails.logger.info "Role: #{invitation.role&.titleize || 'N/A'}"
    Rails.logger.info "Delivery: #{invitation.delivery_method.titleize}"
    Rails.logger.info "Expires: #{invitation.expires_at.strftime('%B %d, %Y at %I:%M %p')}"
    Rails.logger.info ""
    Rails.logger.info "🔗 INVITATION URL:"
    Rails.logger.info context['invitation_url']
    Rails.logger.info ""
    Rails.logger.info "Copy this URL to test the invitation flow!"
    Rails.logger.info "#{separator}\n"
    
    # Also output to STDOUT for terminal visibility
    puts "\n#{separator}"
    puts "🎉 INVITATION CREATED - #{invitation.invitation_type.upcase}"
    puts separator
    puts "🔗 INVITATION URL:"
    puts context['invitation_url']
    puts "#{separator}\n"
  end
  
  # Find appropriate template for invitation type
  def find_template(invitation)
    # Convert invitation_type to template_type (e.g., 'company_user' -> 'company_user_invitation')
    template_type = "#{invitation.invitation_type}_invitation"
    
    # Try to find company-specific template first
    if @company
      template = CommunicationTemplate
                 .active
                 .for_company(@company.id)
                 .by_type(template_type)
                 .for_channel(invitation.delivery_method == 'sms' ? 'sms' : 'email')
                 .first
      
      return template if template
    end
    
    # Fall back to platform template
    CommunicationTemplate
      .active
      .platform_wide
      .by_type(template_type)
      .for_channel(invitation.delivery_method == 'sms' ? 'sms' : 'email')
      .first
  end
  
  # Build template context
  def build_invitation_context(invitation, raw_token)
    frontend_url = ENV['FRONTEND_URL'] || 'https://localhost:5173'
    
    # Use unified invitation path
    invitation_path = '/invitations/accept'
    
    # Parse first/last name from recipient_name
    first_name = nil
    last_name = nil
    if invitation.recipient_name.present?
      parts = invitation.recipient_name.split(' ', 2)
      first_name = parts[0]
      last_name = parts[1] if parts.length > 1
    end
    
    # Get platform settings
    platform_general = PlatformSetting.general
    platform_branding = PlatformSetting.branding
    platform_name = platform_general[:platformName] || platform_general['platformName'] || 'RenterInsight'
    
    # Get logo URL
    logo_value = platform_branding[:logo] || platform_branding['logo']
    
    # Ensure logo URL is absolute (emails need full URLs)
    if logo_value.present?
      # If logo starts with http:// or https://, use as-is
      if logo_value.start_with?('http://', 'https://')
        platform_logo_url = logo_value
      else
        # Otherwise, prepend frontend URL to make it absolute
        platform_logo_url = "#{frontend_url}#{logo_value.start_with?('/') ? logo_value : '/' + logo_value}"
      end
    else
      # Fallback to default logo
      platform_logo_url = "#{frontend_url}/platform-logo.png"
    end
    
    # Log logo URL in development for debugging
    if Rails.env.development?
      Rails.logger.info "🖼️  Platform Logo URL: #{platform_logo_url}"
    end
    
    # Determine the display role - prefer location_role for location-based invitations
    display_role = if invitation.location_role.present?
      invitation.location_role.titleize.gsub('_', ' ')
    elsif invitation.role.present?
      invitation.role.titleize.gsub('_', ' ')
    else
      'Team Member'
    end
    
    Rails.logger.info "🎭 [InvitationService] Building context - location_role: #{invitation.location_role.inspect}, role: #{invitation.role.inspect}, display_role: #{display_role}"
    
    {
      'recipient_name' => invitation.recipient_name || invitation.email.split('@').first.capitalize,
      'first_name' => first_name || invitation.email.split('@').first.capitalize,
      'last_name' => last_name || '',
      'email' => invitation.email,
      'phone' => invitation.phone,
      'role' => display_role,
      'role_name' => display_role,
      'location_role' => invitation.location_role&.titleize&.gsub('_', ' '),
      'company_role' => invitation.role&.titleize&.gsub('_', ' '),
      'invited_by' => invitation.invited_by.name || invitation.invited_by.email,
      'inviter_name' => invitation.invited_by.name || invitation.invited_by.email,
      'company_name' => invitation.company&.name,
      'platform_name' => platform_name,
      'invitation_url' => "#{frontend_url}#{invitation_path}?token=#{raw_token}",
      'registration_url' => "#{frontend_url}#{invitation_path}?token=#{raw_token}",
      'invitation_token' => raw_token,
      'invitation_code' => raw_token[0..5].upcase,
      'invitation_expires' => invitation.expires_at.strftime('%B %d, %Y at %I:%M %p'),
      'expires_at' => invitation.expires_at.strftime('%B %d, %Y at %I:%M %p'),
      'days_until_expiry' => ((invitation.expires_at - Time.current) / 1.day).round,
      'setup_instructions' => invitation.message || 'Please complete your account setup by clicking the link above.',
      'login_url' => "#{frontend_url}/login",
      'message' => invitation.message,
      'platform_logo_url' => platform_logo_url
    }
  end
  
  # Send invitation via email
  def send_email_invitation(invitation, template, context)
    # Get email-specific template if needed
    email_template = template.channel == 'email' ? template : find_template_for_channel(invitation, 'email')
    
    unless email_template
      raise TemplateNotFoundError, "No email template found"
    end
    
    # Render template
    rendered = email_template.render(context)
    
    # Send via CommunicationService
    result = CommunicationService.send_email(
      communicable: invitation,
      to: invitation.email,
      subject: rendered[:subject],
      body: rendered[:body],
      category: 'invitations',
      skip_preference_check: true, # Invitations always send
      metadata: {
        invitation_id: invitation.id,
        invitation_type: invitation.invitation_type
      }
    )
    
    unless result[:success]
      raise DeliveryFailedError, "Email delivery failed: #{result[:error]}"
    end
    
    Rails.logger.info("✅ Invitation email sent to #{invitation.email}")
  end
  
  # Send invitation via SMS
  def send_sms_invitation(invitation, template, context)
    # Get SMS-specific template if needed
    sms_template = template.channel == 'sms' ? template : find_template_for_channel(invitation, 'sms')
    
    unless sms_template
      raise TemplateNotFoundError, "No SMS template found"
    end
    
    # Render template
    rendered = sms_template.render(context)
    
    # Send via CommunicationService
    result = CommunicationService.send_sms(
      communicable: invitation,
      to: invitation.phone,
      body: rendered[:body],
      category: 'invitations',
      skip_preference_check: true, # Invitations always send
      metadata: {
        invitation_id: invitation.id,
        invitation_type: invitation.invitation_type
      }
    )
    
    unless result[:success]
      raise DeliveryFailedError, "SMS delivery failed: #{result[:error]}"
    end
    
    Rails.logger.info("✅ Invitation SMS sent to #{invitation.phone}")
  end
  
  # Normalize location_ids to array of integers
  def normalize_location_ids(location_ids)
    return [] if location_ids.blank?
    
    ids = location_ids.is_a?(Array) ? location_ids : [location_ids]
    ids.map(&:to_i).reject(&:zero?).uniq
  end

  # Find template for specific channel
  def find_template_for_channel(invitation, channel)
    # Convert invitation_type to template_type (e.g., 'company_user' -> 'company_user_invitation')
    template_type = "#{invitation.invitation_type}_invitation"
    
    # Try company-specific first
    if @company
      template = CommunicationTemplate
                 .active
                 .for_company(@company.id)
                 .by_type(template_type)
                 .for_channel(channel)
                 .first
      
      return template if template
    end
    
    # Fall back to platform
    CommunicationTemplate
      .active
      .platform_wide
      .by_type(template_type)
      .for_channel(channel)
      .first
  end
  
  
  # Create a placeholder user record when invitation is sent
  def create_invited_user_placeholder(invitation, recipient_name)
    Rails.logger.info "📧 [InvitationService] Creating placeholder user for #{invitation.email}"
    Rails.logger.info "📧 [InvitationService] Location IDs: #{invitation.location_ids.inspect}"
    Rails.logger.info "📧 [InvitationService] Location Role: #{invitation.location_role}"
    
    # Check if user already exists
    existing_user = User.find_by(email: invitation.email)
    if existing_user
      Rails.logger.info "📧 [InvitationService] User already exists: #{existing_user.id}"
      # Ensure existing user has RBAC role assigned
      assign_rbac_role_to_user(existing_user, invitation.role, invitation.company_id)
      # Assign to locations immediately
      assignments = assign_user_to_locations_safe(invitation, existing_user)
      Rails.logger.info "📧 [InvitationService] Location assignments for existing user: #{assignments.length}"
      return existing_user
    end
    
    # Parse name
    first_name = nil
    last_name = nil
    if recipient_name.present?
      parts = recipient_name.split(' ', 2)
      first_name = parts[0]
      last_name = parts[1] if parts.length > 1
    end
    
    # Create user with invited status
    user = User.create!(
      email: invitation.email,
      phone: invitation.phone,
      first_name: first_name,
      last_name: last_name,
      name: recipient_name,
      role: invitation.role || 'staff',
      permissions: invitation.permissions || [],
      status: 'invited',
      invitation_id: invitation.id,
      company_id: invitation.company_id,
      password: SecureRandom.hex(32) # Temporary password, will be replaced on acceptance
    )
    
    Rails.logger.info "📧 [InvitationService] Created placeholder user: #{user.id} (#{user.email})"
    
    # Assign RBAC role
    assign_rbac_role_to_user(user, invitation.role, invitation.company_id)
    
    # Assign to locations immediately so they show in Assigned Users
    assignments = assign_user_to_locations_safe(invitation, user)
    Rails.logger.info "📧 [InvitationService] Location assignments for new user: #{assignments.length}"
    
    user
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.error("❌ [InvitationService] Could not create placeholder user: #{e.message}")
    Rails.logger.error(e.backtrace.first(3).join("\n"))
    nil
  end
  
  # Safe wrapper for location assignment with detailed logging
  def assign_user_to_locations_safe(invitation, user)
    Rails.logger.info "📍 [InvitationService] Assigning user #{user.id} to locations"
    Rails.logger.info "📍 [InvitationService] Raw location_ids: #{invitation.location_ids.inspect} (class: #{invitation.location_ids.class})"
    Rails.logger.info "📍 [InvitationService] Parsed location_ids: #{invitation.parsed_location_ids.inspect}"
    Rails.logger.info "📍 [InvitationService] has_location_assignments?: #{invitation.has_location_assignments?}"
    Rails.logger.info "📍 [InvitationService] company_id: #{invitation.company_id}"
    
    if !invitation.has_location_assignments?
      Rails.logger.warn "⚠️ [InvitationService] No location assignments - location_ids is empty"
      return []
    end
    
    if !invitation.company_id
      Rails.logger.warn "⚠️ [InvitationService] No company_id on invitation"
      return []
    end
    
    assignments = []
    location_role_value = invitation.location_role || 'location_staff'
    
    invitation.parsed_location_ids.each do |loc_id|
      Rails.logger.info "📍 [InvitationService] Looking for location #{loc_id} in company #{invitation.company_id}"
      
      location = Location.find_by(id: loc_id, company_id: invitation.company_id)
      unless location
        Rails.logger.warn "⚠️ [InvitationService] Location #{loc_id} not found in company #{invitation.company_id}"
        next
      end
      
      Rails.logger.info "📍 [InvitationService] Found location: #{location.id} (#{location.name})"
      
      user_location = UserLocation.find_or_initialize_by(
        user_id: user.id,
        location_id: location.id
      )
      
      user_location.company_id = invitation.company_id
      user_location.location_role = location_role_value
      user_location.assigned_by = @invited_by&.id&.to_s
      user_location.active = true
      
      Rails.logger.info "📍 [InvitationService] UserLocation attributes: #{user_location.attributes.except('created_at', 'updated_at')}"
      
      if user_location.save
        assignments << user_location
        Rails.logger.info "✅ [InvitationService] Assigned user #{user.id} to location #{location.id} with role #{location_role_value}"
      else
        Rails.logger.error "❌ [InvitationService] Failed to assign user #{user.id} to location #{location.id}: #{user_location.errors.full_messages.join(', ')}"
      end
    end
    
    assignments
  end
  
  # Assign RBAC role to user based on role identifier
  def assign_rbac_role_to_user(user, role_identifier, company_id)
    return unless user && company_id
    return unless role_identifier.present?
    
    # Use User model's assign_rbac_role method
    assignment = user.assign_rbac_role(
      role_identifier,
      company_id: company_id,
      assigned_by: @invited_by
    )
    
    if assignment
      Rails.logger.info "✅ [InvitationService] RBAC role assigned to user #{user.id} (#{user.email})"
    else
      Rails.logger.warn "⚠️ [InvitationService] Could not assign RBAC role '#{role_identifier}' to user #{user.id}"
    end
    
    assignment
  end
  
  # Create user from invitation
  def create_user_from_invitation(invitation, user_params)
    case invitation.invitation_type
    when 'company_user'
      create_company_user(invitation, user_params)
    when 'portal_user'
      create_portal_user(invitation, user_params)
    when 'tenant'
      create_tenant(invitation, user_params)
    end
  end
  
  def create_company_user(invitation, user_params)
    Rails.logger.info "👤 [InvitationService] Accepting invitation for #{invitation.email}"
    
    # Find existing invited user
    user = User.find_by(email: invitation.email)
    
    if user
      Rails.logger.info "👤 [InvitationService] Updating existing placeholder user: #{user.id}"
      
      # Update existing placeholder user with full details
      user.update!(
        first_name: user_params[:first_name],
        last_name: user_params[:last_name],
        name: user_params[:name] || "#{user_params[:first_name]} #{user_params[:last_name]}".strip,
        phone: user_params[:phone],
        password: user_params[:password],
        status: 'active',
        mfa_enabled: false
      )
      
      # Ensure RBAC role is assigned (may have been set during placeholder creation, but verify)
      assign_rbac_role_to_user(user, invitation.role, invitation.company_id)
      
      # Ensure user to locations assignment (may already exist from placeholder creation)
      existing_assignments = UserLocation.where(user_id: user.id).count
      Rails.logger.info "👤 [InvitationService] User has #{existing_assignments} existing location assignments"
      
      if existing_assignments == 0
        Rails.logger.info "👤 [InvitationService] Creating location assignments on acceptance"
        assign_user_to_locations_safe(invitation, user)
      end
      
      user
    else
      Rails.logger.info "👤 [InvitationService] No placeholder found - creating new user"
      
      # Fallback: create new user if somehow doesn't exist
      new_user = User.create!(
        email: invitation.email,
        phone: invitation.phone,
        name: user_params[:name],
        first_name: user_params[:first_name],
        last_name: user_params[:last_name],
        password: user_params[:password],
        role: invitation.role || 'staff',
        permissions: invitation.permissions,
        status: 'active',
        company_id: invitation.company_id,
        mfa_enabled: false
      )
      
      # Assign RBAC role
      assign_rbac_role_to_user(new_user, invitation.role, invitation.company_id)
      
      # Assign user to locations if specified
      assign_user_to_locations_safe(invitation, new_user)
      
      new_user
    end
  end
  
  def create_portal_user(invitation, user_params)
    # First create or find a Contact
    contact = Contact.find_or_create_by!(
      email: invitation.email,
      company_id: invitation.company_id
    ) do |c|
      c.first_name = user_params[:first_name] || invitation.recipient_name&.split&.first
      c.last_name = user_params[:last_name] || invitation.recipient_name&.split&.last
      c.phone = invitation.phone
    end
    
    # Then create BuyerPortalAccess
    BuyerPortalAccess.create!(
      buyer: contact,
      email: invitation.email,
      password: user_params[:password],
      portal_enabled: true
    )
  end
  
  def create_tenant(invitation, user_params)
    # Use existing company from invitation (DO NOT create new one)
    company = invitation.company
    raise Error, "No company associated with invitation" unless company
    
    # Find or update existing placeholder user
    user = User.find_by(email: invitation.email, company_id: company.id)
    
    if user
      # Update placeholder user created during invitation
      user.update!(
        first_name: user_params[:first_name],
        last_name: user_params[:last_name],
        name: user_params[:name] || "#{user_params[:first_name]} #{user_params[:last_name]}".strip,
        phone: user_params[:phone] || invitation.phone,
        password: user_params[:password],
        status: 'active',
        role: 'tenant',
        mfa_enabled: false
      )
      Rails.logger.info "✅ Updated tenant owner user #{user.id} for company #{company.id} (#{company.name})"
    else
      # Create new user if doesn't exist (fallback)
      user = User.create!(
        email: invitation.email,
        phone: user_params[:phone] || invitation.phone,
        name: user_params[:name] || "#{user_params[:first_name]} #{user_params[:last_name]}".strip,
        first_name: user_params[:first_name],
        last_name: user_params[:last_name],
        password: user_params[:password],
        role: 'tenant',
        permissions: invitation.permissions || [],
        company_id: company.id,
        status: 'active',
        mfa_enabled: false
      )
      Rails.logger.info "✅ Created tenant owner user #{user.id} for company #{company.id} (#{company.name})"
    end
    
    user
  end
end
