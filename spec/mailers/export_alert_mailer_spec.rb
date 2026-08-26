# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ExportAlertMailer, type: :mailer do
  let(:company) { Company.create!(name: "Alert Co #{SecureRandom.hex(4)}") }
  let(:user) do
    User.create!(email: "alert-#{SecureRandom.hex(4)}@example.com", password: 'password123',
                 first_name: 'A', last_name: 'L', company_id: company.id)
  end
  let(:job) do
    ExportJob.create!(company_id: company.id, user_id: user.id, module_type: 'leads',
                      format: 'json', status: 'completed', row_count: 9_703,
                      selected_fields: %w[first_name email], watermark_token: 'EXP-DEADBEEFDEADBEEF',
                      requested_ip: '203.0.113.7', acknowledged_at: Time.current)
  end

  it 'renders a large-export alert to the platform support address' do
    mail = described_class.large_export(job.id)

    expect(mail.to).to eq([Brand.current.support_email])
    expect(mail.subject).to include(company.name, '9703', 'leads')
    expect(mail.body.encoded).to include('EXP-DEADBEEFDEADBEEF', '203.0.113.7', user.email)
  end

  it 'does nothing when the job is gone' do
    expect { described_class.large_export(-1).message }.not_to raise_error
  end
end
