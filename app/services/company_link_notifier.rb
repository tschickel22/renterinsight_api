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
    def invite_email(link)
      dealer = link.dealer_company
      esc = ->(v) { ERB::Util.html_escape(v.to_s) }
      subject = "#{dealer.name} wants to link with you on #{Brand.current.name}"
      body = <<~HTML
        <p>Hello,</p>
        <p>#{esc.(dealer.name)} would like to send install jobs to your company through #{esc.(Brand.current.name)}, as #{esc.(link.dealer_vendor.name)}.</p>
        <p>Once linked, jobs they hand you arrive in your own company with the customer's details, and the progress you record goes back to their project.</p>
        <p>To accept, sign in to #{esc.(Brand.current.name)} as an admin of your company and open <strong>Linked companies</strong>. If you don't use #{esc.(Brand.current.name)} yet, reply to #{esc.(dealer.name)}.</p>
      HTML
      CommunicationService.send_email(
        company: dealer, to: link.invite_email, subject: subject,
        body: ProjectNotificationService.send(:wrap_html_minimal, body, subject),
        category: 'project_notification', communicable: link
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
