# frozen_string_literal: true

# Load a mapped GoHighLevel snapshot into a company (backlog E84). See
# Migrations::Ghl::Loader for what it does and does not touch.
#
#   bin/rails ghl:load COMPANY_ID=7 BUNDLE=/tmp/ehs_bundle.json.gz DRY_RUN=1
#   bin/rails ghl:load COMPANY_ID=7 BUNDLE=... STEPS=setup,vendors   # some steps
#   bin/rails ghl:status COMPANY_ID=7
#
# FALLBACK_USER_EMAIL: who calls and appointments are logged under when their
# GHL user has no DealerTide account (those tables require a user).
require 'zlib'

namespace :ghl do
  desc 'Load a mapped GoHighLevel bundle into a company (DRY_RUN=1 rolls back)'
  task load: :environment do
    company = Company.find(ENV.fetch('COMPANY_ID'))
    path = ENV.fetch('BUNDLE')
    raw = path.end_with?('.gz') ? Zlib::GzipReader.open(path, &:read) : File.read(path)
    data = JSON.parse(raw)
    if data['company_id'] && data['company_id'].to_i != company.id && ENV['ALLOW_OTHER_COMPANY'].blank?
      abort "Bundle was mapped for company #{data['company_id']}; this is #{company.id} (#{company.name}). Set ALLOW_OTHER_COMPANY=1 to load it anyway."
    end
    steps = ENV['STEPS'].present? ? ENV['STEPS'].split(',').map(&:strip) : Migrations::Ghl::Loader::STEPS
    fallback = ENV['FALLBACK_USER_EMAIL'].present? ? company.users.find_by!(email: ENV['FALLBACK_USER_EMAIL'].downcase) : nil
    puts "Bundle #{File.basename(path)} mapped #{data['mapped_at']}; loading into company #{company.id} #{company.name}"
    Migrations::Ghl::Loader.new(
      company: company, data: data, batch: ENV['BATCH'].presence || "ghl_#{Time.current.strftime('%Y%m%d_%H%M')}",
      dry_run: ENV['DRY_RUN'].present?, steps: steps, fallback_user: fallback
    ).run
  end

  desc 'Count what GoHighLevel migrations have loaded into a company'
  task status: :environment do
    company = Company.find(ENV.fetch('COMPANY_ID'))
    MigrationRecord.where(company_id: company.id, source_system: 'ghl').group(:batch, :source_type).count
                   .sort.each { |(b, t), n| puts "#{b}  #{t}: #{n}" }
  end
end
