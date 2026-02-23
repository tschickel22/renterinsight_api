# frozen_string_literal: true

# Run with: bin/rails s3:configure_cors
# Sets CORS policy on the S3 bucket to allow PDF viewing from frontend origins

namespace :s3 do
  desc "Configure CORS on S3 bucket for PDF iframe viewing"
  task configure_cors: :environment do
    require 'aws-sdk-s3'

    region      = ENV['AWS_REGION'] || 'us-west-2'
    bucket_name = ENV['AWS_S3_BUCKET'] || 'renterinsight-website-assets-staging'

    client = Aws::S3::Client.new(
      region: region,
      access_key_id: ENV['AWS_ACCESS_KEY_ID'],
      secret_access_key: ENV['AWS_SECRET_ACCESS_KEY']
    )

    cors_config = {
      cors_configuration: {
        cors_rules: [
          {
            allowed_origins: [
              "https://localhost:5173",
              "https://localhost:3001",
              "https://staging.crm.landlordinsight.com",
              "https://crm.landlordinsight.com",
              "https://app.renterinsight.com",
              "*"  # Fallback — S3 objects are already public via bucket policy
            ],
            allowed_methods: ["GET", "HEAD"],
            allowed_headers: ["*"],
            expose_headers: ["Content-Length", "Content-Type", "ETag"],
            max_age_seconds: 86400
          }
        ]
      }
    }

    begin
      client.put_bucket_cors(bucket: bucket_name, cors_configuration: cors_config[:cors_configuration])
      puts "✅ CORS configured on bucket: #{bucket_name}"
      puts "   Allowed origins: #{cors_config[:cors_configuration][:cors_rules].first[:allowed_origins].join(', ')}"
    rescue Aws::S3::Errors::ServiceError => e
      puts "❌ Failed to set CORS: #{e.message}"
    end

    # Verify
    begin
      resp = client.get_bucket_cors(bucket: bucket_name)
      puts "\n📋 Current CORS rules:"
      resp.cors_rules.each_with_index do |rule, i|
        puts "   Rule #{i + 1}:"
        puts "     Origins: #{rule.allowed_origins.join(', ')}"
        puts "     Methods: #{rule.allowed_methods.join(', ')}"
        puts "     Headers: #{rule.allowed_headers.join(', ')}"
      end
    rescue Aws::S3::Errors::NoSuchCORSConfiguration
      puts "⚠️  No CORS configuration found after setting — check permissions"
    end
  end
end
