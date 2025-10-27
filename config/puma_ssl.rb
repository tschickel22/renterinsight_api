# Puma SSL Configuration for Local Development
# This file enables HTTPS for local development to match staging/production environments
#
# Usage: bundle exec puma -C config/puma_ssl.rb
#
# Prerequisites:
# 1. Install mkcert: https://github.com/FiloSottile/mkcert
# 2. Generate certificates: mkcert localhost 127.0.0.1
# 3. Certificates should be: localhost+1.pem and localhost+1-key.pem

# Load base puma configuration settings
threads_count = ENV.fetch("RAILS_MAX_THREADS", 3)
threads threads_count, threads_count

# Allow puma to be restarted by `bin/rails restart` command.
plugin :tmp_restart

# Run the Solid Queue supervisor inside of Puma for single-server deployments
plugin :solid_queue if ENV["SOLID_QUEUE_IN_PUMA"]

# Specify the PID file. Defaults to tmp/pids/server.pid in development.
# In other environments, only set the PID file if requested.
pidfile ENV["PIDFILE"] if ENV["PIDFILE"]

# Check if SSL certificates exist
cert_path = File.expand_path('../localhost+1.pem', __dir__)
key_path = File.expand_path('../localhost+1-key.pem', __dir__)

if File.exist?(cert_path) && File.exist?(key_path)
  # SSL Configuration
  ssl_bind '0.0.0.0', '3001', {
    key: key_path,
    cert: cert_path,
    verify_mode: 'none'
  }
  
  puts "🔒 Starting Rails API with HTTPS on https://localhost:3001"
  puts "   Certificate: #{cert_path}"
  puts "   Key: #{key_path}"
else
  # Fallback to HTTP if certificates don't exist
  bind 'tcp://0.0.0.0:3001'
  
  puts "⚠️  SSL certificates not found, falling back to HTTP"
  puts "   Expected cert: #{cert_path}"
  puts "   Expected key: #{key_path}"
  puts "   To enable HTTPS: See QUICK_START_HTTPS.md"
  puts "   Starting Rails API with HTTP on http://localhost:3001"
end

# Optional: Log configuration in development
if ENV['RAILS_ENV'] == 'development' || !ENV['RAILS_ENV']
  puts "📝 Running in development mode"
  puts "   CORS enabled for:"
  puts "   - http://localhost:5173"
  puts "   - https://localhost:5173"
  puts "   - https://staging.crm.landlordinsight.com"
end
