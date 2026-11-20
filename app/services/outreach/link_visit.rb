# frozen_string_literal: true

module Outreach
  # Was a visit to an outreach link a person, or a machine checking it?
  # (backlog E105, 2026-11-20)
  #
  # Production, wave 2, Chad Mosher: the text went out at 18:55:03 and the
  # video link was opened at 18:55:06 and 18:55:20, both from Google addresses
  # (74.125.213.7, 192.178.15.196). That is Google Messages building the link
  # preview, or Google's spam check, before the phone even showed the text. It
  # was counted as "watched the video 2x". Mail scanners do the same to emails
  # (ScannerOpen, Campaigns::ScannerClick).
  module LinkVisit
    # Nobody reads a message and taps its link this fast. Every machine visit
    # measured so far landed inside it.
    QUICK = 60.seconds
    # Previews and spam checks run as the message arrives. After this, a visit
    # from these networks is treated as a person (Google Fi, a Pixel's proxy).
    MACHINE_WINDOW = 10.minutes
    MACHINE_NETWORKS = %w[
      74.125.0.0/16 192.178.0.0/16 66.249.64.0/19 64.233.160.0/19 66.102.0.0/20 72.14.192.0/18
      209.85.128.0/17 216.239.32.0/19 108.177.0.0/17 173.194.0.0/16 172.217.0.0/16 142.250.0.0/15
      17.0.0.0/8
    ].map { |cidr| IPAddr.new(cidr) }.freeze
    MACHINE_AGENT = /bot|crawler|spider|preview|scanner|facebookexternalhit|slurp|whatsapp|skypeuripreview|bitlybot|curl|wget|python|go-http|okhttp/i

    module_function

    # Why this visit is a machine, or nil for a person.
    def machine_reason(target, ip:, user_agent:, at: Time.current)
      return 'link checker' if user_agent.to_s.match?(MACHINE_AGENT)

      sent_at = target.last_sent_at
      return nil if sent_at.nil?
      return 'opened seconds after sending' if at - sent_at < QUICK
      return 'preview from a phone or mail service' if at - sent_at < MACHINE_WINDOW && machine_network?(ip)

      nil
    end

    def machine_network?(ip)
      addr = IPAddr.new(ip.to_s)
      MACHINE_NETWORKS.any? { |net| net.include?(addr) }
    rescue IPAddr::InvalidAddressError
      false
    end

    # Clicks and checkup views already recorded that came in the first minute
    # after a message went out: removed, and first_click_at worked out again.
    # Returns how many were removed.
    def reclassify!(scope = OutreachEvent.all)
      removed = 0
      scope.where(event_type: %w[clicked report_viewed]).includes(:outreach_target).find_each do |event|
        sent = OutreachEvent.where(outreach_target_id: event.outreach_target_id, event_type: 'sent')
                            .where(occurred_at: (event.occurred_at - QUICK)..event.occurred_at).exists?
        next unless sent

        event.destroy!
        removed += 1
        target = event.outreach_target
        first = target.outreach_events.where(event_type: 'clicked').minimum(:occurred_at)
        target.update_columns(first_click_at: first)
      end
      removed
    end
  end
end
