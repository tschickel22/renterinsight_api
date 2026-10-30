# frozen_string_literal: true

# Notices and the invite email for company links and linked jobs (E68 step 5).
# Each notice is created in the receiving company, so it shows in that
# company's bell and Review Updates and links to that company's own pages.
# ProjectNotices sends the email and text each person's switches allow (E87).
class CompanyLinkNotifier
  class << self
    def invited(link)
      dealer = link.dealer_company
      # Not the dealer's own people: someone who works at both shares the email
      # and can only accept from the installer's company.
      admins_with_email(link.invite_email).reject { |u| u.company_id == dealer.id }.group_by(&:company).each do |company, users|
        ProjectNotices.deliver(
          users: users, company: company, type: :project_link_request, notifiable: link,
          title: "Link request from #{dealer.name}",
          message: "#{dealer.name} wants to send install jobs to #{company.name}. Review it under Linked companies.",
          item: { kind: 'link_request', subject: link, title: "Link request from #{dealer.name}",
                  detail: "#{dealer.name} wants to send install jobs to #{company.name}. Read the agreement and accept under Linked companies, Links.",
                  from_name: dealer.name }
        )
      end
      CompanyLinkInviteEmailJob.perform_later(link.id)
    end

    def invite_email(link)
      dealer = link.dealer_company
      brand = Brand.current
      branding = (PlatformSetting.branding || {}).to_h.with_indifferent_access
      subject = "#{dealer.name} wants to link with you on #{brand.name}"
      html = ActionController::Base.render(
        template: 'company_link_mailer/invite', layout: 'branded_mailer', formats: [:html],
        assigns: {
          brand: brand, dealer: dealer, vendor_name: link.dealer_vendor.name,
          accept_url: "#{Brand.app_url.to_s.chomp('/')}/linked-companies?view=links",
          brand_primary: branding[:primaryColor].presence || '#0F2A52',
          brand_accent: branding[:secondaryColor].presence || '#00AFA8',
          brand_font: "#{branding[:fontFamily].presence || 'Poppins'}, -apple-system, 'Segoe UI', Arial, sans-serif",
          footer_note: "You are receiving this because #{dealer.name} invited this address to link companies on #{brand.name}."
        }
      )
      # Embedded, not linked: Outlook blocks remote images.
      logo = brand.logo_url.present? ? InvitationService.new(invited_by: link.invited_by).send(:build_inline_logo_attachments, brand.logo_url) : []
      CommunicationService.send_email(
        company: dealer, to: link.invite_email, subject: subject, body: html,
        category: 'project_notification', communicable: link, inline_images: logo
      )
    rescue => e
      Rails.logger.error("[CompanyLinkNotifier] invite email: #{e.message}")
    end

    def accepted(link)
      ProjectNotices.close!(subject: link, kinds: 'link_request', resolution: 'accepted', by: link.accepted_by)
      deliver(dealer_people(link), link.dealer_company, :company_link, link,
              "#{link.installer_company.name} accepted your link",
              "You can now send jobs to #{link.dealer_vendor.name} from a project's Progress tab.")
    end

    def ended(link, by:)
      ProjectNotices.close!(subject: link, kinds: 'link_request', resolution: 'ended', by: by)
      if by.id == link.dealer_company_id
        return unless link.installer_company

        deliver(installer_admins(link), link.installer_company, :company_link, link,
                "#{by.name} ended the link", 'No new jobs will be sent across it. Jobs already handed off stay where they are.')
      else
        deliver(dealer_people(link), link.dealer_company, :company_link, link,
                "#{by.name} ended the link", 'No new jobs will be sent across it. Jobs already handed off stay where they are.')
      end
    end

    # The job waits in the installer's Review Updates until they accept or
    # decline it, and they get an email and a text (their switches allowing).
    def job_offered(project_link)
      dealer = project_link.dealer_company
      text = "#{project_link.scope_label} for #{project_link.dealer_project.customer_display_name}."
      text += " Their note: #{project_link.note}" if project_link.note.present?
      deliver(installer_admins(project_link.company_link), project_link.installer_company, :project_job_offered, project_link,
              "New job from #{dealer.name}", "#{text} Accept or decline it under Jobs from dealers.",
              item: { kind: 'job_offered', title: "New job from #{dealer.name}: #{project_link.scope_label}",
                      detail: text, from_name: dealer.name })
    end

    def job_answered(project_link)
      ProjectNotices.close!(subject: project_link, kinds: 'job_offered', resolution: project_link.status,
                            by: project_link.responded_by)
      verb = project_link.accepted? ? 'accepted' : 'declined'
      text = "#{project_link.scope_label} on #{project_link.dealer_project.name}."
      text += " Reason: #{project_link.decline_reason}" if project_link.decline_reason.present?
      title = "#{project_link.installer_company.name} #{verb} the job"
      deliver(dealer_recipients(project_link), project_link.dealer_company, :project_job_answered, project_link, title, text,
              item: { kind: 'job_answered', title: title, detail: text, from_name: project_link.installer_company.name,
                      project: project_link.dealer_project, phase: project_link.dealer_phase,
                      assigned_user: project_link.dealer_project.owner })
    end

    def job_cancelled(project_link)
      # Whatever was waiting on either side about this job is moot now.
      ProjectNotices.close!(subject: project_link, resolution: 'taken back', by: project_link.dealer_company)
      project_link.link_changes.each { |c| ProjectNotices.close!(subject: c, resolution: 'taken back', by: project_link.dealer_company) }
      return unless project_link.installer_project || project_link.offered? || project_link.status == 'cancelled'

      dealer = project_link.dealer_company
      text = "#{project_link.scope_label} for #{project_link.dealer_project.customer_display_name}."
      deliver(installer_admins(project_link.company_link), project_link.installer_company, :project_job_taken_back, project_link,
              "#{dealer.name} took back a job", text,
              item: { kind: 'job_taken_back', title: "#{dealer.name} took back #{project_link.scope_label}", detail: text,
                      from_name: dealer.name, project: project_link.installer_project })
    end

    def job_billed(project_link)
      amount = ActiveSupport::NumberHelper.number_to_currency(project_link.dealer_bill&.total_amount || project_link.fee_amount)
      installer = project_link.installer_company.name
      text = "#{amount} for #{project_link.scope_label} on #{project_link.dealer_project.name}. It's a draft bill waiting for approval."
      subject = project_link.dealer_bill || project_link
      deliver(dealer_recipients(project_link), project_link.dealer_company, :project_installer_bill, subject,
              "Bill from #{installer}", text,
              item: { kind: 'installer_bill', title: "Bill from #{installer}: #{amount}", detail: text, from_name: installer,
                      project: project_link.dealer_project, phase: project_link.dealer_phase,
                      assigned_user: project_link.dealer_project.owner,
                      metadata: { amount: (project_link.dealer_bill&.total_amount || project_link.fee_amount).to_s } })
    end

    # ── Rate cards, price requests and change orders (step 6) ──────────────

    def rate_card_submitted(card)
      link = card.company_link
      installer = link.installer_company.name
      text = "Version #{card.version}, #{card.items.size} #{'line'.pluralize(card.items.size)}. Approve it under Linked companies, Links."
      # A new version replaces the one still waiting.
      link.rate_cards.where.not(id: card.id).each { |c| ProjectNotices.close!(subject: c, kinds: 'rate_card', resolution: 'replaced') }
      deliver(dealer_people(link), link.dealer_company, :project_rate_card, card, "New rate card from #{installer}", text,
              item: { kind: 'rate_card', title: "Rate card from #{installer} (version #{card.version})", detail: text,
                      from_name: installer })
    end

    def rate_card_decided(card)
      link = card.company_link
      ProjectNotices.close!(subject: card, kinds: 'rate_card', resolution: card.status, by: card.decided_by)
      verb = card.approved? ? 'approved' : 'declined'
      text = card.approved? ? 'Jobs priced from it are approved when they are sent.' : card.decline_reason.presence || 'Send a new version from Linked companies, Links.'
      title = "#{link.dealer_company.name} #{verb} your rate card"
      deliver(installer_admins(link), link.installer_company, :project_rate_card_decided, card, title, "Version #{card.version}. #{text}",
              item: { kind: 'rate_card_decided', title: "#{title} (version #{card.version})", detail: text,
                      from_name: link.dealer_company.name })
    end

    def rate_card_withdrawn(card)
      ProjectNotices.close!(subject: card, kinds: 'rate_card', resolution: 'withdrawn', by: card.company_link.installer_company)
    end

    def change_requested(change)
      pl = change.project_link
      amount = ActiveSupport::NumberHelper.number_to_currency(change.amount)
      installer = pl.installer_company.name
      title = change.price? ? "#{installer} priced a job at #{amount}" : "Change order from #{installer}: #{amount}"
      what = change.price? ? 'Its phases' : (change.dealer_phase&.name || 'The phases it covers')
      text = "#{pl.scope_label} on #{pl.dealer_project.name}. #{what} can't start until you approve it."
      text += " #{change.description}" if change.description.present?
      deliver(dealer_recipients(pl), pl.dealer_company, :project_change_order, change, title, text,
              item: { kind: change.price? ? 'installer_quote' : 'change_order', title: title, detail: text, from_name: installer,
                      project: pl.dealer_project, phase: change.dealer_phase || pl.dealer_phase,
                      assigned_user: pl.dealer_project.owner, metadata: { amount: change.amount.to_s } })
    end

    def change_withdrawn(change)
      ProjectNotices.close!(subject: change, resolution: 'withdrawn', by: change.project_link.installer_company)
    end

    def change_decided(change)
      pl = change.project_link
      ProjectNotices.close!(subject: change, kinds: %w[installer_quote change_order], resolution: change.status, by: change.decided_by)
      verb = change.status == 'approved' ? 'approved' : 'declined'
      text = "#{change.price? ? 'Price' : "Change order #{change.number}"} #{ActiveSupport::NumberHelper.number_to_currency(change.amount)} on #{pl.scope_label}."
      text += " Reason: #{change.decline_reason}" if change.decline_reason.present?
      title = "#{pl.dealer_company.name} #{verb} your #{change.price? ? 'price' : 'change order'}"
      deliver(installer_admins(pl.company_link), pl.installer_company, :project_change_decided, change, title, text,
              item: { kind: 'change_decided', title: title, detail: text, from_name: pl.dealer_company.name,
                      project: pl.installer_project })
    end

    # The dealer made the linked installer's vendor record the owner of a
    # project or phases (Change on the Progress tab), rather than sending the
    # job across. phases: nil for the whole project.
    def vendor_assigned(link, project, phases, actor: nil)
      dealer = link.dealer_company.name
      what = if phases.include?(nil) then project.name
             elsif phases.one? then "#{phases.first.name} on #{project.name}"
             else "#{phases.size} phases on #{project.name} (#{phases.map(&:name).first(3).to_sentence})"
             end
      by = actor ? " by #{actor.full_name.presence || actor.email}" : ''
      title = "#{dealer} assigned you work"
      text = "#{what}#{by}."
      deliver(installer_admins(link), link.installer_company, :project_assigned, link, title, text,
              item: { kind: 'assigned', title: "#{dealer} assigned you: #{what}", detail: text, from_name: dealer })
    rescue => e
      Rails.logger.error("[CompanyLinkNotifier] vendor_assigned for link #{link&.id}: #{e.class}: #{e.message}")
    end

    # One company moved an estimated date on a handed-off phase and it was
    # copied across: the other company hears about it. One open item per
    # phase, refreshed by later moves until someone marks it seen.
    def date_changed(project_link, phase:, changes:, by_company:)
      pl = project_link
      to_installer = by_company.id == pl.dealer_company_id
      company = to_installer ? pl.installer_company : pl.dealer_company
      project = phase.project
      people = if to_installer
                 [project.owner].compact.select { |u| u.company_id == company.id && u.active? }.presence ||
                   installer_admins(pl.company_link)
               else
                 dealer_recipients(pl)
               end
      title = "#{by_company.name} changed dates on #{phase.name}"
      text = "#{changes.join('; ')}. #{project.name}."
      ProjectNotices.deliver(users: people, company: company, type: :project_date_changed, notifiable: phase,
                             title: title, message: text, action_url: link_to_project(project),
                             item: { kind: 'date_changed', subject: phase, title: title, detail: text,
                                     from_name: by_company.name, project: project, phase: phase,
                                     assigned_user: project.owner })
    rescue => e
      Rails.logger.error("[CompanyLinkNotifier] date_changed for link #{project_link&.id}: #{e.class}: #{e.message}")
    end

    private

    def link_to_project(project)
      project.deal_id ? "/deals/#{project.deal_id}?tab=progress" : "/deals/projects/#{project.id}"
    end

    def deliver(users, company, type, notifiable, title, message, item: nil)
      ProjectNotices.deliver(users: users, company: company, type: type, notifiable: notifiable,
                             title: title, message: message, item: item && item.merge(subject: notifiable))
    end

    def admins_with_email(email)
      User.where('LOWER(email) = ?', email.to_s.downcase).where(status: 'active').includes(:company)
          .select { |u| u.company && u.effective_admin? }
    end

    # A platform admin who set the link up from inside a company (support, or
    # testing) is not one of its users, so they are told as well as its admins
    # (E68 test 6.3: the rate card reached Summit Park's admins, not the tester).
    def installer_admins(link)
      return [] unless link.installer_company

      (link.installer_company.users.where(status: 'active').select(&:effective_admin?) +
        acting_admins(link.accepted_by)).uniq
    end

    def dealer_people(link)
      [link.invited_by].compact.select { |u| u.company_id == link.dealer_company_id && u.active? }.presence ||
        (link.dealer_company.users.where(status: 'active').select(&:effective_admin?) + acting_admins(link.invited_by)).uniq
    end

    def acting_admins(user)
      [user].compact.select { |u| u.platform_admin? && u.active? }
    end

    def dealer_recipients(project_link)
      [project_link.dealer_project.owner, project_link.offered_by].compact.uniq
        .select { |u| u.company_id == project_link.dealer_company_id && u.active? }
        .presence || dealer_people(project_link.company_link)
    end
  end
end
