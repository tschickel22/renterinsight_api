# frozen_string_literal: true

module Onboarding
  # The intro to a client's onboarding plan (backlog E97): an email, and a
  # text from our own number, telling the client's people we built their
  # setup plan and where to find it (Getting started, Your project). Sent
  # when we start the client, or later from their page if we held it back.
  # What was sent, when and by whom is kept in a company setting.
  module Intro
    module_function

    KEY = 'onboarding_intro'

    # Who gets it unless we pick: the client's admins and followers.
    def default_people(company) = Checklist.client_people(company)

    def status(company)
      s = Setting.get('Company', company.id, KEY, nil)
      s.is_a?(Hash) && s['sent_at'].present? ? s.slice('sent_at', 'by', 'to', 'emails', 'texts') : nil
    end

    # @return [Hash] emails: n, texts: n, skipped_texts: [names without a mobile number]
    def send!(company, actor:, user_ids:, email: true, sms: true, note: nil)
      people = User.where(company_id: company.id, id: Array(user_ids)).select(&:active?)
      raise Checklist::Invalid, 'Pick at least one person' if people.empty?
      raise Checklist::Invalid, 'Pick email, text or both' unless email || sms

      note = note.to_s.strip.first(1000).presence
      url = link
      emails = 0
      texts = 0
      no_phone = []
      people.each do |u|
        if email && u.email.present?
          OnboardingMailer.intro(u, company, actor, note).deliver_now
          emails += 1
        end
        next unless sms

        if u.phone.blank?
          no_phone << u.full_name
          next
        end
        result = TwilioSmsService.send_via_master(to: u.phone, body: text(u, company, url))
        result[:success] ? texts += 1 : Rails.logger.warn("[Onboarding::Intro] text to user #{u.id} failed: #{result[:error]}")
      end

      Setting.set('Company', company.id, KEY, {
        'sent_at' => Time.current.iso8601, 'by' => actor&.full_name, 'to' => people.map(&:full_name),
        'emails' => emails, 'texts' => texts
      })
      { emails: emails, texts: texts, skipped_texts: no_phone }
    end

    def link = "#{Brand.current.app_url.to_s.chomp('/')}/?getting_started=1"

    def text(user, company, url)
      brand = Brand.current.name
      "#{brand}: Hi #{user.first_name.presence || 'there'}, we built a setup plan for #{company.name}. " \
        "In #{brand}, click Getting started at the top of the screen, then Your project. #{url}"
    end
  end
end
