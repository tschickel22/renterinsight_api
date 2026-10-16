# frozen_string_literal: true

namespace :active_storage do
  # Copies every uploaded file from the web server's disk to S3 and points its
  # record there. Safe to run again: files already on S3 are skipped, and a
  # file is only repointed once S3 holds it with the same checksum.
  # Then set ACTIVE_STORAGE_SERVICE=amazon so new uploads go to S3 as well.
  desc 'Copy uploaded files from the local disk to S3 (the amazon service)'
  task to_s3: :environment do
    target = ActiveStorage::Blob.services.fetch(:amazon)
    already = ActiveStorage::Blob.where.not(service_name: 'local').count
    moved = failed = 0
    ActiveStorage::Blob.where(service_name: 'local').find_each do |blob|
      unless blob.service.exist?(blob.key)
        puts "MISSING on disk: blob #{blob.id} #{blob.filename}"
        failed += 1
        next
      end
      blob.open do |file|
        target.upload(blob.key, file, checksum: blob.checksum, content_type: blob.content_type)
      end
      blob.update_columns(service_name: 'amazon')
      moved += 1
    rescue StandardError => e
      puts "FAILED blob #{blob.id} #{blob.filename}: #{e.message}"
      failed += 1
    end
    puts "Moved #{moved}, already on S3 #{already}, failed #{failed}."
  end
end
