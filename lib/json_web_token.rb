class JsonWebToken
  # Resolve the JWT signing secret once at first use.
  # Priority: ENV['JWT_SECRET'] > credentials.jwt_secret > secret_key_base
  #
  # IMPORTANT: ENV['JWT_SECRET'] must be a stable value across deploys.
  # If it changes (or is missing), ALL existing tokens become invalid
  # and every user is logged out on the next server restart.
  def self.secret_key
    @secret_key ||= resolve_secret_key
  end

  def self.resolve_secret_key
    # 1. Prefer explicit JWT_SECRET env var (most reliable across restarts)
    if ENV['JWT_SECRET'].present?
      Rails.logger.info "[JsonWebToken] Using JWT_SECRET env var for token signing"
      return ENV['JWT_SECRET']
    end

    # 2. Try encrypted credentials
    begin
      cred_secret = Rails.application.credentials.jwt_secret
      if cred_secret.present?
        Rails.logger.info "[JsonWebToken] Using credentials.jwt_secret for token signing"
        return cred_secret
      end
    rescue ActiveSupport::MessageEncryptor::InvalidMessage => e
      Rails.logger.warn "[JsonWebToken] Could not decrypt credentials: #{e.message}"
    end

    # 3. Fall back to secret_key_base (stable if SECRET_KEY_BASE env var is set)
    Rails.logger.warn "[JsonWebToken] ⚠️  Falling back to secret_key_base for JWT signing. " \
                      "Set JWT_SECRET env var for explicit control."
    Rails.application.secret_key_base
  end
  private_class_method :resolve_secret_key
  
  # Extended token expiry: 7 days (for staging/production stability)
  STANDARD_EXP = 7.days
  
  # Refresh token expiry: 7 days
  REFRESH_EXP = 7.days
  
  # Encode a JWT token with user data
  # @param payload [Hash] The data to encode (must include user_id)
  # @param exp [ActiveSupport::Duration] Token expiration time
  # @return [String] The encoded JWT token
  def self.encode(payload, exp = STANDARD_EXP.from_now)
    payload[:exp] = exp.to_i
    payload[:iat] = Time.now.to_i # Issued at
    JWT.encode(payload, secret_key, 'HS256')
  end
  
  # Decode a JWT token
  # @param token [String] The JWT token to decode
  # @return [HashWithIndifferentAccess, nil] The decoded payload or nil if invalid
  def self.decode(token)
    body = JWT.decode(token, secret_key, true, { algorithm: 'HS256' })[0]
    HashWithIndifferentAccess.new(body)
  rescue JWT::ExpiredSignature => e
    Rails.logger.info("[JsonWebToken] Token expired: #{e.message}")
    nil
  rescue JWT::DecodeError => e
    Rails.logger.warn("[JsonWebToken] Decode error: #{e.message}")
    nil
  end
  
  # Generate a standard access token for a user
  # @param user [User] The user to generate a token for
  # @return [String] The encoded access token
  def self.generate_access_token(user)
    payload = {
      user_id: user.id,
      email: user.email,
      role: user.role,
      type: 'access'
    }
    
    # Add company_id only for non-platform admins
    if user.respond_to?(:company_id) && user.company_id.present?
      # Platform admins should NOT have company_id in their JWT
      unless user.respond_to?(:platform_admin?) && user.platform_admin?
        payload[:company_id] = user.company_id
      end
    end
    
    encode(payload, STANDARD_EXP.from_now)
  end
  
  # Generate an impersonation access token
  # Contains the target user's identity plus impersonated_by for audit trail
  # @param target_user [User] The user being impersonated
  # @param admin_user [User] The platform admin performing impersonation
  # @return [String] The encoded impersonation token
  def self.generate_impersonation_token(target_user, admin_user)
    payload = {
      user_id: target_user.id,
      email: target_user.email,
      role: target_user.role,
      type: 'access',
      impersonated_by: admin_user.id
    }

    # Include company_id for non-platform users
    if target_user.company_id.present? && !target_user.platform_admin?
      payload[:company_id] = target_user.company_id
    end

    encode(payload, STANDARD_EXP.from_now)
  end

  # Generate a refresh token for a user
  # @param user [User] The user to generate a token for
  # @return [String] The encoded refresh token
  def self.generate_refresh_token(user)
    encode({
      user_id: user.id,
      type: 'refresh'
    }, REFRESH_EXP.from_now)
  end
  
  # Generate a temporary token for MFA verification
  # This token is short-lived and only valid for MFA verification
  # @param user [User] The user to generate a token for
  # @return [String] The encoded temporary MFA token
  def self.generate_mfa_temp_token(user)
    encode({
      user_id: user.id,
      type: 'mfa_temp'
    }, 5.minutes.from_now) # Short 5-minute expiry
  end
  
  # Generate a temporary token for portal user MFA verification
  # @param portal_user [BuyerPortalAccess] The portal user to generate a token for
  # @return [String] The encoded temporary MFA token
  def self.generate_mfa_temp_token_portal(portal_user)
    encode({
      buyer_portal_access_id: portal_user.id,
      type: 'mfa_temp_portal'
    }, 5.minutes.from_now) # Short 5-minute expiry
  end
  
  # Generate both access and refresh tokens
  # @param user [User] The user to generate tokens for
  # @return [Hash] Hash containing :access_token and :refresh_token
  def self.generate_token_pair(user)
    {
      access_token: generate_access_token(user),
      refresh_token: generate_refresh_token(user),
      expires_in: STANDARD_EXP.to_i
    }
  end
  
  # Verify if a token is a valid refresh token
  # @param token [String] The token to verify
  # @return [Boolean] True if valid refresh token
  def self.valid_refresh_token?(token)
    decoded = decode(token)
    decoded && decoded[:type] == 'refresh'
  end
end
