# frozen_string_literal: true

# Bell notices and the invite email for company links and linked jobs
# (E68 step 5). Each notice is created in the receiving company, so it shows
# in that company's bell and links to that company's own pages.
class CompanyLinkNotifier
  class << self
    def invited(link)
      dealer = link.dealer_company
      # Not the dealer's own people: someone who works at both shares the email
      # and can only accept from the installer's company.
      admins_with_email(link.invite_email).reject { |u| u.company_id == dealer.id }.each do |u|
        bell(u, :company_link, "Link request from #{dealer.name}",
             "#{dealer.name} wants to send install jobs to #{u.company.name}. Review it under Linked companies.", link)
      end
      CompanyLinkInviteEmailJob.perform_later(link.id)
    end

    # Sent from a job: an inline send held the dealer's request for seconds.
    # Platform-branded (logo, colors, footer), since it invites the installer
    # into the platform, with a button straight to the Links tab where they
    # accept. Sign-in keeps the link, so it lands there after logging in.
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
      dealer_people(link).each do |u|
        bell(u, :company_link, "#{link.installer_company.name} accepted your link",
             "You can now send jobs to #{link.dealer_vendor.name} from a project's Progress tab.", link)
      end
    end

    def ended(link, by:)
      others = by.id == link.dealer_company_id ? installer_admins(link) : dealer_people(link)
      others.each do |u|
        bell(u, :company_link, "#{by.name} ended the link", 'No new jobs will be sent across it. Jobs already handed off stay where they are.', link)
      end
    end

    def job_offered(project_link)
      installer_admins(project_link.company_link).each do |u|
        bell(u, :project_link, "New job from #{project_link.dealer_company.name}",
             "#{project_link.scope_label} for #{project_link.dealer_project.customer_display_name}. Accept or decline it under Jobs from dealers.", project_link)
      end
    end

    def job_answered(project_link)
      verb = project_link.accepted? ? 'accepted' : 'declined'
      text = "#{project_link.scope_label} on #{project_link.dealer_project.name}."
      text += " Reason: #{project_link.decline_reason}" if project_link.decline_reason.present?
      dealer_recipients(project_link).each do |u|
        bell(u, :project_link, "#{project_link.installer_company.name} #{verb} the job", text, project_link)
      end
    end

    def job_cancelled(project_link)
      return unless project_link.installer_project || project_link.offered? || project_link.status == 'cancelled'

      installer_admins(project_link.company_link).each do |u|
        bell(u, :project_link, "#{project_link.dealer_company.name} took back a job",
             "#{project_link.scope_label} for #{project_link.dealer_project.customer_display_name}.", project_link)
      end
    end

    def job_billed(project_link)
      dealer_recipients(project_link).each do |u|
        amount = ActiveSupport::NumberHelper.number_to_currency(project_link.dealer_bill&.total_amount || project_link.fee_amount)
        bell(u, :project_link, "Bill from #{project_link.installer_company.name}",
             "#{amount} for #{project_link.scope_label} on #{project_link.dealer_project.name}. It's a draft bill waiting for approval.", project_link.dealer_bill || project_link)
      end
    end

    private

    def bell(user, type, title, message, notifiable)
      cfg = Notification::TYPES[type] || { category: 'service', priority: 'normal' }
      Notification.create!(recipient: user, company_id: user.company_id, notification_type: type.to_s,
                           category: cfg[:category], priority: cfg[:priority], title: title, message: message,
                           notifiable: notifiable, read: false)
    rescue => e
      Rails.logger.error("[CompanyLinkNotifier] bell: #{e.message}")
    end

    def admins_with_email(email)
      User.where('LOWER(email) = ?', email.to_s.downcase).where(status: 'active').includes(:company)
          .select { |u| u.company && u.effective_admin? }
    end

    def installer_admins(link)
      return [] unless link.installer_company

      link.installer_company.users.where(status: 'active').select(&:effective_admin?)
    end

    def dealer_people(link)
      [link.invited_by].compact.select { |u| u.company_id == link.dealer_company_id && u.active? }.presence ||
        link.dealer_company.users.where(status: 'active').select(&:effective_admin?)
    end

    def dealer_recipients(project_link)
      [project_link.dealer_project.owner, project_link.offered_by].compact.uniq
        .select { |u| u.company_id == project_link.dealer_company_id && u.active? }
        .presence || dealer_people(project_link.company_link)
    end
  end
end
