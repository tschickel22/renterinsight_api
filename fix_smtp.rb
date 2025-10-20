file_path = 'app/services/providers/email/smtp_provider.rb'
content = File.read(file_path)

old_code = <<~'CODE'
      def initialize
        @config = {
          address: ENV['SMTP_ADDRESS'] || Rails.application.config.action_mailer.smtp_settings[:address],
          port: ENV['SMTP_PORT'] || Rails.application.config.action_mailer.smtp_settings[:port] || 587,
          domain: ENV['SMTP_DOMAIN'] || Rails.application.config.action_mailer.smtp_settings[:domain],
          user_name: ENV['SMTP_USERNAME'] || Rails.application.config.action_mailer.smtp_settings[:user_name],
          password: ENV['SMTP_PASSWORD'] || Rails.application.config.action_mailer.smtp_settings[:password],
          authentication: ENV['SMTP_AUTHENTICATION'] || 'plain',
          enable_starttls_auto: true
        }
      end
CODE

new_code = <<~'CODE'
      def initialize
        smtp_settings = Rails.application.config.action_mailer.smtp_settings || {}
        
        @config = {
          address: ENV['SMTP_ADDRESS'] || smtp_settings[:address],
          port: ENV['SMTP_PORT'] || smtp_settings[:port] || 587,
          domain: ENV['SMTP_DOMAIN'] || smtp_settings[:domain],
          user_name: ENV['SMTP_USERNAME'] || smtp_settings[:user_name],
          password: ENV['SMTP_PASSWORD'] || smtp_settings[:password],
          authentication: ENV['SMTP_AUTHENTICATION'] || 'plain',
          enable_starttls_auto: true
        }
      end
CODE

content.gsub!(old_code.strip, new_code.strip)
File.write(file_path, content)
puts "✅ Fixed!"
