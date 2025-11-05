class JsonWebToken
  SECRET_KEY = Rails.application.credentials.jwt_secret || ENV['JWT_SECRET'] || Rails.application.secret_key_base
  
  # Extended expiration for staging/production stability
  def self.encode(payload, exp = 7.days.from_now)
    payload[:exp] = exp.to_i
    JWT.encode(payload, SECRET_KEY, 'HS256')
  end
  
  def self.decode(token)
    body = JWT.decode(token, SECRET_KEY, true, { algorithm: 'HS256' })[0]
    HashWithIndifferentAccess.new(body)
  rescue JWT::ExpiredSignature => e
    Rails.logger.info "[JsonWebToken] Token expired: #{e.message}"
    nil
  rescue JWT::DecodeError => e
    Rails.logger.warn "[JsonWebToken] Decode error: #{e.message}"
    nil
  end
end
