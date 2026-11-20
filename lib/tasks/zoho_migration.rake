# frozen_string_literal: true

# Load a mapped Zoho CRM snapshot into a company. See Migrations::Zoho::Loader
# for what it does and does not touch.
#
#   bin/rails zoho:load COMPANY_ID=22 BUNDLE=/tmp/ri_zoho.json.gz DRY_RUN=1
#   bin/rails zoho:load COMPANY_ID=22 BUNDLE=... STEPS=setup,accounts   # some steps
#   bin/rails zoho:status COMPANY_ID=22
#
# FALLBACK_USER_EMAIL: who records are owned by when their Zoho owner has no
# DealerTide account. Worth setting for this migration: Zoho has owners that
# DealerTide does not, and a record with no owner falls off every "mine" view.
require 'zlib'

namespace :zoho do
  desc 'Load a mapped Zoho CRM bundle into a company (DRY_RUN=1 rolls back)'
  task load: :environment do
    company = Company.find(ENV.fetch('COMPANY_ID'))
    path = ENV.fetch('BUNDLE')
    # Production has no shared disk, so the bundle comes from the private
    # bucket: BUNDLE=s3://zoho-import/ri_zoho.json.gz (key in the Active
    # Storage bucket).
    if path.start_with?('s3://')
      key = path.delete_prefix('s3://')
      blob = ActiveStorage::Blob.service.download(key)
      raw = key.end_with?('.gz') ? Zlib::GzipReader.new(StringIO.new(blob)).read : blob
    else
      raw = path.end_with?('.gz') ? Zlib::GzipReader.open(path, &:read) : File.read(path)
    end
    data = JSON.parse(raw)
    if data['company_id'] && data['company_id'].to_i != company.id && ENV['ALLOW_OTHER_COMPANY'].blank?
      abort "Bundle was mapped for company #{data['company_id']}; this is #{company.id} (#{company.name}). Set ALLOW_OTHER_COMPANY=1 to load it anyway."
    end
    steps = ENV['STEPS'].present? ? ENV['STEPS'].split(',').map(&:strip) : Migrations::Zoho::Loader::STEPS
    fallback = ENV['FALLBACK_USER_EMAIL'].present? ? company.users.find_by!(email: ENV['FALLBACK_USER_EMAIL'].downcase) : nil
    # USER_EMAIL_REWRITE="@renterinsight.com=@ri-staging.invalid" matches owners to stand-in users on a test company.
    rewrite = ENV['USER_EMAIL_REWRITE'].presence&.split('=', 2)
    # SKIP_MATCHES_IN=14: leave out anything that tenant already has (and what hangs off it).
    skip_in = ENV['SKIP_MATCHES_IN'].present? ? Company.find(ENV['SKIP_MATCHES_IN']) : nil
    puts "Bundle #{File.basename(path)} mapped #{data['mapped_at']}; loading into company #{company.id} #{company.name}"
    Migrations::Zoho::Loader.new(
      company: company, data: data, batch: ENV['BATCH'].presence || "zoho_#{Time.current.strftime('%Y%m%d_%H%M')}",
      dry_run: ENV['DRY_RUN'].present?, steps: steps, fallback_user: fallback, user_email_rewrite: rewrite,
      skip_matches_in: skip_in
    ).run
  end

  desc 'Count what Zoho migrations have loaded into a company'
  task status: :environment do
    company = Company.find(ENV.fetch('COMPANY_ID'))
    MigrationRecord.where(company_id: company.id, source_system: 'zoho').group(:batch, :source_type).count
                   .sort.each { |(b, t), n| puts "#{b}  #{t}: #{n}" }
  end
end
