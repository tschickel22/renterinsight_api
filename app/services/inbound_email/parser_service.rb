# frozen_string_literal: true

module InboundEmail
  class ParserService
    attr_reader :email_data
    
    def initialize(email_data)
      @email_data = email_data
    end
    
    # Parse the email and return structured data
    def parse
      require 'mail'
      require 'base64'
      
      # Extract Base64 content from SES notification
      content = email_data['content']
      decoded_content = Base64.decode64(content)
      
      # Parse MIME email using Mail gem
      mail = Mail.new(decoded_content)
      
      # Extract token from To address (e.g., reply+lead-123@mail.renterinsight.com)
      to_address = mail.to.first
      token = extract_token(to_address)
      
      # Extract body (prefer text, fallback to HTML)
      body_text = mail.text_part&.decoded || mail.body.decoded
      body_html = mail.html_part&.decoded
      
      {
        from: mail.from.first,
        to: mail.to.first,
        subject: mail.subject,
        body_text: body_text,
        body_html: body_html,
        timestamp: mail.date || Time.current,
        token: token,
        message_id: mail.message_id
      }
    rescue => e
      Rails.logger.error "[ParserService] Error parsing email: #{e.message}"
      Rails.logger.error e.backtrace.first(5).join("\n")
      { error: e.message }
    end
    
    private
    
    # Extract token from email address
    # reply+lead-123@mail.renterinsight.com → { prefix: "reply", token: "lead-123" }
    # crm+bcc-456@mail.renterinsight.com → { prefix: "crm", token: "bcc-456" }
    def extract_token(email_address)
      return nil unless email_address
      
      # Match: prefix+token@domain
      match = email_address.match(/([^+]+)\+([^@]+)@/)
      
      if match
        {
          prefix: match[1],  # "reply" or "crm"
          token: match[2]    # "lead-123" or "bcc-456"
        }
      else
        nil
      end
    end
  end
end
