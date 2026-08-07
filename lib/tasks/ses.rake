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
    # Reports by default and only applies with APPLY=1, because applying is the dangerous
    # direction on a domain that is already sending. apply_mail_from! sets
    # behavior_on_mx_failure REJECT_MESSAGE, so once SES checks and finds no MX at the new
    # MAIL FROM subdomain it marks the identity Failed and rejects EVERY message from that
    # domain. Publish the MX and TXT this prints, then re-run with APPLY=1.
    desc 'Report which verified sending domains have no custom MAIL FROM ' \
         '(DOMAIN=hostname to narrow, APPLY=1 to apply after publishing DNS)'
    task mail_from: :environment do
      scope = CompanyDomain.email_verified
      scope = scope.where(hostname: ENV['DOMAIN']) if ENV['DOMAIN'].present?
      domains = scope.to_a

      abort 'No verified sending domains matched.' if domains.empty?
      apply = ENV['APPLY'] == '1'

      domains.each do |domain|
        if domain.ses_mail_from_domain.present?
          puts "#{domain.hostname}: has #{domain.ses_mail_from_domain} (#{domain.ses_mail_from_status})"
          next
        end

        candidate = "#{Ses::IdentityManager.mail_from_prefix}.#{domain.hostname}"

        unless apply
          puts "#{domain.hostname}: NO MAIL FROM. Publish these, then re-run with APPLY=1:"
          puts "  MX  #{candidate}  10 feedback-smtp.#{Ses::Region.current}.amazonses.com"
          puts "  TXT #{candidate}  \"v=spf1 include:amazonses.com ~all\""
          next
        end

        Ses::IdentityManager.new(domain).ensure_mail_from!
        applied = domain.reload.ses_mail_from_domain

        message = if applied.present?
                    "#{domain.hostname}: applied #{applied} (#{domain.ses_mail_from_status})"
                  else
                    # apply_mail_from! refuses to publish over a subdomain that already
                    # receives mail, so this is expected for a domain already using that name.
                    "#{domain.hostname}: SKIPPED, #{candidate} already has MX records"
                  end
        puts message
      rescue Ses::IdentityManager::SesError => e
        puts "#{domain.hostname}: FAILED, #{e.message}"
      end
    end
  end
end
