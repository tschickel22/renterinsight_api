# frozen_string_literal: true

module Ops
  # Emails and texts the platform owner that a server is in trouble.
  #
  # Who: OPS_ALERT_EMAIL and OPS_ALERT_PHONE (Render environment, never in the
  # code). Nothing is sent where neither is set, so a laptop or a test stays
  # quiet. Each kind of alert goes out at most once per `every`, counted in the
  # database because production has no shared cache: each server process
  # would otherwise send its own copy.
  module Alert
    module_function

    EVERY = 30.minutes

    def enabled?
      email.present? || phone.present?
    end

    def email = ENV['OPS_ALERT_EMAIL'].presence
    def phone = ENV['OPS_ALERT_PHONE'].presence

    # "Production" or "Staging", so a text says which.
    def where
      Rails.env.staging? || ENV['RENDER_SERVICE_NAME'].to_s.include?('staging') ? 'Staging' : 'Production'
    end

    # => true when it went out.
    def notify!(key, subject, body, every: EVERY)
      return false unless enabled?
      return false unless claim!(key, subject, every)

      deliver(subject, body)
      true
    end

    # Sends without asking the database first (the outside watcher, when the
    # server or the database may be what is down).
    def deliver(subject, body)
      subject = "#{where}: #{subject}"
      begin
        OpsAlertMailer.alert(email, subject, body).deliver_now if email
      rescue StandardError => e
        Rails.logger.error("[Ops::Alert] email failed: #{e.message}")
      end
      if phone
        result = TwilioSmsService.send_via_master(to: phone, body: "#{subject}. #{body}".squish.first(320))
        Rails.logger.error("[Ops::Alert] text failed: #{result[:error]}") unless result[:success]
      end
    rescue StandardError => e
      Rails.logger.error("[Ops::Alert] #{e.class}: #{e.message}")
    end

    # Only one process wins the right to send within `every`.
    def claim!(key, subject, every)
      mark = "alert:#{key}"
      now = Time.current
      OpsMark.insert({ key: mark, at: now - every - 1, note: nil }, unique_by: :key)
      OpsMark.where(key: mark).where(at: ...(now - every)).update_all(at: now, note: subject.first(250)) == 1
    end
  end
end
