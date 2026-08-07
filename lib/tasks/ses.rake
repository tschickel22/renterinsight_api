# frozen_string_literal: true

namespace :ses do
  namespace :events do
    desc 'Report whether the SES bounce/complaint/delivery pipeline is wired up (read-only)'
    task status: :environment do
      status = Ses::EventPipeline.status

      set_state = case status[:configuration_set_exists]
                  when true then 'exists'
                  when false then 'MISSING'
                  else 'UNKNOWN, could not read it (see errors below)'
                  end

      puts "Region            : #{status[:region]}"
      puts "Configuration set : #{status[:configuration_set]} (#{set_state})"
      puts "Webhook URL       : #{status[:webhook_url]}"

      dest = status[:event_destination]
      if dest
        puts "Event destination : #{dest[:name]} enabled=#{dest[:enabled]} events=#{dest[:event_types].join(',')}"
        puts "Topic ARN         : #{dest[:topic_arn]}"
      else
        puts 'Event destination : MISSING (SES is publishing nothing)'
        puts "Topic ARN         : #{status[:topic_arn] || 'none'}"
      end

      sub = status[:subscription]
      puts(if sub.nil?
             'Subscription      : MISSING (nothing delivers to the webhook)'
           elsif sub[:confirmed]
             "Subscription      : confirmed (#{sub[:subscription_arn]})"
           else
             'Subscription      : PENDING CONFIRMATION (re-run ses:events:setup)'
           end)

      if status[:errors].any?
        puts
        puts 'Could not read some of this:'
        status[:errors].each { |e| puts "  - #{e}" }
        puts 'These are read failures, not proof that the resource is absent.'
      end

      ready = status[:configuration_set_exists] == true && dest&.dig(:enabled) && sub&.dig(:confirmed)
      puts
      puts(if ready
             'Pipeline is live.'
           elsif status[:errors].any?
             'Pipeline state is UNKNOWN. Fix the read permissions above before changing anything.'
           else
             'Pipeline is NOT live. Run: bin/rails ses:events:setup'
           end)
    end

    desc 'Create/repair the SES configuration set, SNS topic, event destination and webhook subscription'
    task setup: :environment do
      report = Ses::EventPipeline.provision!

      puts "Configuration set : #{report[:configuration_set]} (#{report[:configuration_set_created] ? 'created' : 'already existed'})"
      puts "Topic ARN         : #{report[:topic_arn]}"
      puts "Topic policy      : #{report[:topic_policy_updated] ? 'SES publish granted' : 'already granted'}"
      puts "Event destination : #{report[:event_destination][:action]} events=#{report[:event_destination][:event_types].join(',')}"

      sub = report[:subscription]
      puts "Subscription      : #{sub[:action]} confirmed=#{sub[:confirmed]} endpoint=#{sub[:endpoint]}"

      unless sub[:confirmed]
        puts
        puts 'SNS has posted a confirmation to the webhook, which confirms it automatically.'
        puts 'Re-run bin/rails ses:events:status in a few seconds to check it took.'
      end
    rescue Ses::EventPipeline::SesError => e
      abort "SES event pipeline setup failed: #{e.message}"
    end
  end

  namespace :domains do
    desc 'Apply the custom MAIL FROM to verified sending domains that never got one ' \
         '(DOMAIN=hostname for one, otherwise all)'
    task mail_from: :environment do
      scope = CompanyDomain.email_verified
      scope = scope.where(hostname: ENV['DOMAIN']) if ENV['DOMAIN'].present?
      domains = scope.to_a

      abort 'No verified sending domains matched.' if domains.empty?

      domains.each do |domain|
        before = domain.ses_mail_from_domain
        Ses::IdentityManager.new(domain).ensure_mail_from!
        after = domain.reload.ses_mail_from_domain

        puts case
             when after.blank?
               # apply_mail_from! refuses to publish over a subdomain that already receives
               # mail, so this is the expected outcome for a domain using that name already.
               "#{domain.hostname}: SKIPPED, no MAIL FROM applied (subdomain likely already has MX)"
             when before.blank?
               "#{domain.hostname}: applied #{after} (#{domain.ses_mail_from_status}), " \
               'publish its MX and TXT records from the domain settings screen'
             else
               "#{domain.hostname}: already had #{after} (#{domain.ses_mail_from_status})"
             end
      rescue Ses::IdentityManager::SesError => e
        puts "#{domain.hostname}: FAILED, #{e.message}"
      end
    end
  end
end
