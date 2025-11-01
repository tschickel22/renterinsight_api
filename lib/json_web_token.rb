class JsonWebToken
  SECRET_KEY = Rails.application.secret_key_base
  
  # Standard token expiry: 24 hours
  STANDARD_EXP = 24.hours
  
  # Refresh token expiry: 7 days
  REFRESH_EXP = 7.days
  
  # Encode a JWT token with user data
  # @param payload [Hash] The data to encode (must include user_id)
  # @param exp [ActiveSupport::Duration] Token expiration time
  # @return [String] The encoded JWT token
  def self.encode(payload, exp = STANDARD_EXP.from_now)
    payload[:exp] = exp.to_i
    payload[:iat] = Time.now.to_i # Issued at
    JWT.encode(payload, SECRET_KEY)
  end
  
  # Decode a JWT token
  # @param token [String] The JWT token to decode
  # @return [HashWithIndifferentAccess, nil] The decoded payload or nil if invalid
  def self.decode(token)
    body = JWT.decode(token, SECRET_KEY)[0]
    HashWithIndifferentAccess.new(body)
  rescue JWT::DecodeError => e
    Rails.logger.warn("JWT decode error: #{e.message}")
    nil
  rescue JWT::ExpiredSignature => e
    Rails.logger.warn("JWT expired: #{e.message}")
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
    
    # Add company_id if user has one
    payload[:company_id] = user.company_id if user.respond_to?(:company_id) && user.company_id.present?
    
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
