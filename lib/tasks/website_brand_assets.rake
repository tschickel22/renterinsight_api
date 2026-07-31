# frozen_string_literal: true

# Uploads shared brand assets (manufacturer logos, stock home photography) that
# the website templates reference.
#
# The templates previously shipped text-only base64 SVG "logos" — the word
# CLAYTON HOMES set in a system font — which is what made a dealer site look
# unfinished. These are the real marks.
#
# A rake task rather than a migration because it is idempotent-ish infra work
# that may need re-running when a logo changes, and it prints the URLs so they
# can be pasted into the frontend constants file.
#
#   bin/rails "website:upload_brand_assets[/path/to/logos]"
namespace :website do
  desc 'Upload manufacturer logos to S3 and print the URLs for the frontend'
  task :upload_brand_assets, [:dir] => :environment do |_t, args|
    dir = args[:dir].presence || ENV['LOGO_DIR']
    abort 'Usage: bin/rails "website:upload_brand_assets[/path/to/logos]"' if dir.blank?
    abort "Not a directory: #{dir}" unless File.directory?(dir)

    uploader = S3UploadService.new
    results = {}

    Dir.glob(File.join(dir, '*.{png,jpg,jpeg,webp,svg}')).sort.each do |path|
      name = File.basename(path)
      content_type = case File.extname(path).downcase
                     when '.png' then 'image/png'
                     when '.webp' then 'image/webp'
                     when '.svg' then 'image/svg+xml'
                     else 'image/jpeg'
                     end

      file = Struct.new(:body, :content_type, :original_filename) do
        def read = body
        def size = body.bytesize
        def path = original_filename
      end.new(File.binread(path), content_type, name)

      begin
        uploaded = uploader.upload(file, folder: 'brand/manufacturers')
        results[name] = uploaded[:url]
        puts "  ok  #{name} -> #{uploaded[:url]}"
      rescue StandardError => e
        warn "  FAILED #{name}: #{e.message}"
      end
    end

    puts "\n#{results.size} uploaded. Frontend constants:\n\n"
    results.each do |name, url|
      key = File.basename(name, '.*').parameterize.underscore.upcase
      puts "  #{key}: '#{url}',"
    end
  end
end
