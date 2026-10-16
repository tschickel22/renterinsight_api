# frozen_string_literal: true

namespace :uploads do
  # Copies files under UPLOAD_PATH (logos, favicons, vehicle photos saved to
  # the web server's disk) to the public bucket at uploads/<path>, where
  # Api::UploadsController#show already looks when the file is not on disk.
  # Lets the disk go (backlog E79). Safe to run again: files already in the
  # bucket are skipped.
  desc 'Copy UPLOAD_PATH files to the public bucket (uploads/<path>)'
  task to_s3: :environment do
    base = ENV['UPLOAD_PATH'].presence || Rails.root.join('public', 'uploads').to_s
    bucket = ENV.fetch('AWS_S3_BUCKET')
    client = Aws::S3::Client.new(region: ENV['AWS_REGION'] || 'us-west-2')
    copied = present = failed = 0
    Dir.glob(File.join(base, '**', '*')).select { |p| File.file?(p) }.each do |path|
      key = "uploads/#{path.delete_prefix("#{base}/")}"
      begin
        client.head_object(bucket: bucket, key: key)
        present += 1
      rescue Aws::S3::Errors::NotFound
        File.open(path, 'rb') do |f|
          client.put_object(bucket: bucket, key: key, body: f, content_type: Marcel::MimeType.for(Pathname(path)))
        end
        copied += 1
      end
    rescue StandardError => e
      puts "FAILED #{path}: #{e.message}"
      failed += 1
    end
    puts "Copied #{copied}, already there #{present}, failed #{failed}."
  end
end
