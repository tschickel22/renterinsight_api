# frozen_string_literal: true

namespace :turnstile do
  desc 'Add every website domain to the lead form Turnstile widget (adds only, never removes)'
  task sync_domains: :environment do
    unless TurnstileDomainService.configured?
      abort 'Turnstile is not configured (TURNSTILE_SITE_KEY, CLOUDFLARE_ACCOUNT_ID, CLOUDFLARE_API_TOKEN)'
    end

    service = TurnstileDomainService.new
    CompanyDomain.where(web_enabled: true).order(:id).find_each do |domain|
      result = service.allow!(domain.hostname)
      puts "#{domain.hostname}: #{result}"
    rescue TurnstileDomainService::Error => e
      puts "#{domain.hostname}: FAILED #{e.message}"
    end
  end
end
