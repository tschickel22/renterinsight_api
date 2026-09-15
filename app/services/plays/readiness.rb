# frozen_string_literal: true

module Plays
  # What a play needs to work well, checked against the company as it is now:
  # mailboxes, a verified sending domain, a texting number, booking links, a
  # Facebook connection, homes to show, quiet leads to wake.
  #
  # Nothing here stops a play turning on. Each check says what happens without
  # the thing and links to where it is set up. Only a check a play cannot run
  # without is 'missing'; the rest are 'ok' or 'warn'.
  class Readiness
    FIX = {
      domain: { label: 'Verify a sending domain', path: '/settings?tab=domains' },
      communications: { label: 'Set up email and texting', path: '/settings?tab=communications' },
      mailbox: { label: 'Connect a mailbox', path: '/account/settings?tab=email' },
      booking: { label: 'Add a booking link', path: '/account/settings?tab=profile' },
      facebook: { label: 'Connect Facebook', path: '/settings?tab=integrations' },
      inventory: { label: 'Open inventory', path: '/inventory' }
    }.freeze

    HOME_STATUSES = %w[available available_to_order].freeze

    def initialize(play:, company:, installation: nil)
      @play = play
      @company = company
      @installation = installation
    end

    def call
      checks = case @play.kind
               when 'lead_response' then lead_response_checks
               when 'recurring_email' then [homes_check, *email_checks(lead_owner_ids)]
               when 'reengagement' then [quiet_leads_check, *email_checks(lead_owner_ids)]
               when 'landing_page' then landing_page_checks
               when 'deal_followup' then deal_checks
               else []
               end.compact
      { ready: checks.none? { |c| c[:status] == 'missing' }, checks: checks }
    end

    private

    def check(key, status, label, detail, fix = nil)
      { key: key, status: status, label: label, detail: detail, fix: fix && FIX.fetch(fix) }
    end

    def answers
      @answers ||= @installation ? @play.answers_for(@installation) : {}
    end

    def content
      answers['content'] || (@play.respond_to?(:default_content) ? @play.normalize_content(nil) : {})
    end

    # ── Lead response ────────────────────────────────────────────────────

    def lead_response_checks
      reps = rep_ids
      [
        rotation_check(reps),
        mailbox_check(reps),
        booking_check(reps),
        texting_check,
        facebook_check,
        company_email_check,
        domain_check
      ]
    end

    # The reps in this play's rotation once it is on; before that, everyone
    # who could be picked.
    def rep_ids
      return Array(answers['reps_by_location']&.values).flatten.map(&:to_i).uniq if @installation

      User.where(company_id: @company.id, status: 'active').pluck(:id)
    end

    def rotation_check(reps)
      return nil unless @installation

      if reps.any?
        check('rotation', 'ok', 'Reps are chosen', "#{reps.size} #{reps.size == 1 ? 'rep takes' : 'reps take'} new leads from this play.")
      else
        check('rotation', 'missing', 'No reps are chosen', 'New leads have no one to go to. Choose reps in Customize.')
      end
    end

    def texting_check
      return nil unless @play.respond_to?(:texting_ready?)

      unless @play.texting_ready?(@company)
        return check('texting', 'warn', 'No texting number',
                     'Leads get an email and a call task, but no text.', :communications)
      end
      if @installation && !answers['send_texts']
        return check('texting', 'warn', 'Texts are off for this play', 'Turn them on in Customize to text leads who agree to texts.')
      end

      check('texting', 'ok', 'Texting is set up', 'Leads who agree to texts get one from their rep right away.')
    end

    def facebook_check
      sources = @installation ? Array(answers['sources']) : Array(@play.try(:default_sources))
      return nil unless sources.any? { |source| source.to_s.casecmp?('Facebook') }

      if FacebookIntegration.active.where(company_id: @company.id).exists?
        check('facebook', 'ok', 'Facebook Lead Ads connected', 'Leads from your ads arrive on their own.')
      else
        check('facebook', 'warn', 'Facebook Lead Ads not connected',
              'Point your ads at the Facebook Contact form in the meantime. It works without the connection.', :facebook)
      end
    end

    # ── Email ────────────────────────────────────────────────────────────

    def email_checks(user_ids)
      [mailbox_check(user_ids), company_email_check, domain_check]
    end

    def mailbox_check(user_ids)
      users = User.where(company_id: @company.id, status: 'active', id: user_ids).pluck(:id)
      return nil if users.empty?

      connected = UserEmailConnection.where(company_id: @company.id, is_active: true, user_id: users).distinct.count(:user_id)
      if connected == users.size
        check('mailboxes', 'ok', 'Reps send from their own mailbox', "All #{users.size} #{users.size == 1 ? 'rep has' : 'reps have'} a connected mailbox.")
      else
        check('mailboxes', 'warn', "#{connected} of #{users.size} reps have a connected mailbox",
              "Email for the others comes from your location's email, then your company's, then the platform's.", :mailbox)
      end
    end

    def booking_check(user_ids)
      users = User.where(company_id: @company.id, status: 'active', id: user_ids)
      return nil if users.none?

      missing = users.where(booking_url: [nil, '']).count
      if missing.zero?
        check('booking_links', 'ok', 'Reps have booking links', 'First emails include a link to book a time.')
      else
        check('booking_links', 'warn', "#{missing} #{missing == 1 ? 'rep has' : 'reps have'} no booking link",
              'Their first email leaves the booking line out.', :booking)
      end
    end

    def company_email_check
      location_ids = @company.locations.select(:id)
      set_up = Setting.where(key: 'communications').where(
        '(scope_type = ? AND scope_id = ?) OR (scope_type = ? AND scope_id IN (?))',
        'Company', @company.id, 'Location', location_ids
      ).exists?
      if set_up
        check('company_email', 'ok', 'Location or company email is set up', 'It sends anything a rep mailbox does not.')
      else
        check('company_email', 'warn', 'No location or company email',
              'Email without a rep mailbox comes from the platform address instead.', :communications)
      end
    end

    def domain_check
      if CompanyDomain.email_verified.where(company_id: @company.id).exists?
        check('sending_domain', 'ok', 'Sending domain verified', 'Email goes out under your own domain.')
      else
        check('sending_domain', 'warn', 'No verified sending domain',
              'Email still sends, but lands in spam more often.', :domain)
      end
    end

    # ── Weekly homes and cold leads ──────────────────────────────────────

    def lead_owner_ids
      Lead.where(company_id: @company.id, is_converted: [false, nil]).where.not(owner_id: nil).distinct.pluck(:owner_id)
    end

    def homes_check
      homes = @company.vehicles.where(status: HOME_STATUSES)
      homes = homes.where(is_deleted: [false, nil]) if Vehicle.column_names.include?('is_deleted')
      with_photos = homes.where("images IS NOT NULL AND images::text NOT IN ('[]', '')").count
      if with_photos.positive?
        check('homes', 'ok', "#{with_photos} homes with photos to show", 'Each email shows the best matches.')
      else
        check('homes', 'warn', 'No available homes with photos', 'The email shows its button only until homes are added.', :inventory)
      end
    end

    def quiet_leads_check
      days = content['idle_days'].to_i.positive? ? content['idle_days'].to_i : 60
      quiet = Lead.where(company_id: @company.id, is_converted: [false, nil]).where('last_activity_at < ?', days.days.ago).count
      detail = quiet.positive? ? 'They start the emails as soon as the play is on.' : 'Leads start the emails as they go quiet.'
      check('quiet_leads', 'ok', "#{quiet} #{quiet == 1 ? 'lead has' : 'leads have'} been quiet for #{days} days", detail)
    end

    # ── Landing page and deals ───────────────────────────────────────────

    def landing_page_checks
      unless @play.available?(@company)
        return [check('landing_pages', 'missing', 'Landing pages are not in your plan',
                      'Ask us to add them, or add Campaign Desk.')]
      end

      follower = @play.follower_for(@company)
      [
        check('landing_pages', 'ok', 'Landing pages are in your plan', 'The page publishes on your marketing site.'),
        if follower
          check('follow_up', 'ok', "#{follower[:name]} follows up", 'Leads from the page get a first response and a rep.')
        else
          check('follow_up', 'warn', 'No play follows up yet',
                'Turn on New Facebook lead or Walk-in visit, then choose it as the follow-up play.')
        end
      ]
    end

    def deal_checks
      open_deals = Deal.where(company_id: @company.id).where.not(stage: @company.closed_deal_stage_keys)
      without_email = open_deals.left_joins(:contact).where(contacts: { email: [nil, ''] }).count
      checks = []
      checks << if without_email.zero?
                  check('buyer_emails', 'ok', 'Open deals have a buyer email', 'Buyers get the onboarding series when a deal is won.')
                else
                  check('buyer_emails', 'warn', "#{without_email} open #{without_email == 1 ? 'deal has' : 'deals have'} no buyer email",
                        'Those buyers get no onboarding emails. Reps still get their tasks.')
                end
      if content.dig('review_request', 'enabled') == false
        checks << check('review_link', 'warn', 'Review request is off', 'Add your Google or Facebook review link in Customize to turn it on.')
      end
      checks + [company_email_check, domain_check]
    end
  end
end
