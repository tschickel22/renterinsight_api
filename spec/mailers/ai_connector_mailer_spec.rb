# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AiConnectorMailer, type: :mailer do
  let(:company) { Company.create!(name: "Lakeside Homes #{SecureRandom.hex(3)}") }

  def user!(role, status: 'active')
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", password: 'password123', first_name: 'Dana',
                 last_name: 'Reed', company_id: company.id, role: role, status: status)
  end

  describe '#enabled' do
    it 'tells an admin how to give access, install the plugin and what to ask, with no dashes' do
      admin = user!('company_admin')
      mail = described_class.enabled(company.id, admin.id)
      body = mail.body.encoded

      expect(mail.to).to eq([admin.email])
      expect(mail.subject).to include('works with Claude', company.name)
      expect(body).to include('Hi Dana', 'Roles &amp; Permissions', 'Also let it make changes',
                              'Help me close last month.', '/settings?tab=ai-apps', '/settings?tab=users')
      expect(mail.text_part.decoded).to include('Settings, Integrations, AI Apps')
      expect(mail.text_part.decoded + mail.html_part.decoded).not_to match(/[–—]/)
    end

    it 'links the directory listing once it is set, and the docs page before' do
      admin = user!('company_admin')
      expect(described_class.enabled(company.id, admin.id).text_part.decoded).to include('/ai-connector/')

      allow(described_class).to receive(:directory_url).and_return('https://claude.ai/directory/dealertide')
      expect(described_class.enabled(company.id, admin.id).text_part.decoded)
        .to include('https://claude.ai/directory/dealertide')
    end

    it 'sends nothing for a user of another company' do
      other = Company.create!(name: "Other #{SecureRandom.hex(3)}")
      stranger = User.create!(email: "s-#{SecureRandom.hex(4)}@example.com", password: 'password123',
                              first_name: 'S', last_name: 'T', company_id: other.id, role: 'company_admin')
      expect(described_class.enabled(company.id, stranger.id).message.to).to be_nil
    end
  end

  describe 'when AI Apps is switched on' do
    include ActiveJob::TestHelper

    it 'emails each active admin once, and not other staff' do
      admin = user!('company_admin')
      user!('company_admin', status: 'inactive')
      user!('sales_rep')

      expect { TenantModuleOverride.create!(company: company, module_key: 'admin.ai_connector', is_enabled: true) }
        .to have_enqueued_mail(described_class, :enabled).with(company.id, admin.id).exactly(:once)
    end

    it 'emails on the switch from off to on, not on a re-save or for other modules' do
      admin = user!('company_admin')
      row = TenantModuleOverride.create!(company: company, module_key: 'admin.ai_connector', is_enabled: false)

      expect { row.update!(is_enabled: true) }.to have_enqueued_mail(described_class, :enabled).with(company.id, admin.id)
      expect { row.update!(override_reason: 'paid add-on') }.not_to have_enqueued_mail(described_class, :enabled)
      expect { TenantModuleOverride.create!(company: company, module_key: 'marketing.campaigns', is_enabled: true) }
        .not_to have_enqueued_mail(described_class, :enabled)
    end
  end
end
