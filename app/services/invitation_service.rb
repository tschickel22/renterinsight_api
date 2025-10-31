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
    message: nil
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
      message: message
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
    
    # Get appropriate template
    template = find_template(invitation)
    
    unless template
      raise TemplateNotFoundError, "No template found for #{invitation.invitation_type}"
    end
    
    # Build context for template rendering
    context = build_invitation_context(invitation, raw_token)
    
    # Send via email if required
    if invitation.delivery_method.in?(['email', 'both'])
      send_email_invitation(invitation, template, context)
    end
    
    # Send via SMS if required
    if invitation.delivery_method.in?(['sms', 'both'])
      send_sms_invitation(invitation, template, context)
    end
    
    # Update invitation status
    invitation.update!(
      sent_at: Time.current,
      last_sent_at: Time.current
    )
    
    true
  rescue StandardError => e
    Rails.logger.error("Failed to send invitation: #{e.message}")
    raise DeliveryFailedError, "Failed to send invitation: #{e.message}"
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
      .platform
      .by_type(template_type)
      .for_channel(invitation.delivery_method == 'sms' ? 'sms' : 'email')
      .first
  end
  
  # Build template context
  def build_invitation_context(invitation, raw_token)
    frontend_url = ENV['FRONTEND_URL'] || 'https://localhost:5173'
    
    invitation_path = case invitation.invitation_type
                      when 'company_user'
                        '/invitations/company-user'
                      when 'portal_user'
                        '/invitations/portal-user'
                      when 'tenant'
                        '/invitations/tenant'
                      end
    
    {
      'recipient_name' => invitation.recipient_name || invitation.email.split('@').first.capitalize,
      'inviter_name' => invitation.invited_by.name || invitation.invited_by.email,
      'company_name' => invitation.company&.name,
      'invitation_url' => "#{frontend_url}#{invitation_path}?token=#{raw_token}",
      'invitation_code' => raw_token[0..5].upcase, # Short code for SMS
      'expires_at' => invitation.expires_at.strftime('%B %d, %Y at %I:%M %p'),
      'role' => invitation.role&.titleize,
      'message' => invitation.message
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
      .platform
      .by_type(template_type)
      .for_channel(channel)
      .first
  end
  
  
  # Create a placeholder user record when invitation is sent
  def create_invited_user_placeholder(invitation, recipient_name)
    # Check if user already exists
    existing_user = User.find_by(email: invitation.email)
    return existing_user if existing_user
    
    # Parse name
    first_name = nil
    last_name = nil
    if recipient_name.present?
      parts = recipient_name.split(' ', 2)
      first_name = parts[0]
      last_name = parts[1] if parts.length > 1
    end
    
    # Create user with invited status
    User.create!(
      email: invitation.email,
      phone: invitation.phone,
      first_name: first_name,
      last_name: last_name,
      name: recipient_name,
      role: invitation.role || 'staff',
      permissions: invitation.permissions || [],
      status: 'invited',
      invitation_id: invitation.id,
      password: SecureRandom.hex(32) # Temporary password, will be replaced on acceptance
    )
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.warn("Could not create placeholder user: #{e.message}")
    nil
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
    # Find existing invited user
    user = User.find_by(email: invitation.email)
    
    if user
      # Update existing placeholder user with full details
      user.update!(
        first_name: user_params[:first_name],
        last_name: user_params[:last_name],
        name: user_params[:name] || "#{user_params[:first_name]} #{user_params[:last_name]}".strip,
        password: user_params[:password],
        status: 'active',
        mfa_enabled: false
      )
      user
    else
      # Fallback: create new user if somehow doesn't exist
      User.create!(
        email: invitation.email,
        phone: invitation.phone,
        name: user_params[:name],
        first_name: user_params[:first_name],
        last_name: user_params[:last_name],
        password: user_params[:password],
        role: invitation.role || 'staff',
        permissions: invitation.permissions,
        status: 'active',
        mfa_enabled: false
      )
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
    # Create a new company (tenant)
    company = Company.create!(
      name: user_params[:company_name],
      domain: user_params[:domain]
    )
    
    # Create admin user for the new company
    User.create!(
      email: invitation.email,
      phone: invitation.phone,
      name: user_params[:name],
      first_name: user_params[:first_name],
      last_name: user_params[:last_name],
      password: user_params[:password],
      role: 'admin',
      status: 'active'
    )
  end
end
