# frozen_string_literal: true

require 'rails_helper'

# Nurture AI writes {{rep_booking_link}} for booking CTAs. The nurture sender
# has to fill it with the owning rep's link, or it goes out literally.
RSpec.describe ProcessNurtureStepJob, 'rep booking link', type: :job do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:job) { described_class.new }

  def make_rep(booking_url:)
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'Rep', last_name: SecureRandom.hex(2),
                 password: 'Pass1234!', company_id: company.id, role: 'sales_rep', status: 'active',
                 booking_url: booking_url)
  end

  def render(lead)
    context = job.send(:build_merge_context, lead)
    job.send(:render_merge_fields, '<a href="{{rep_booking_link}}">Book here</a>', context)
  end

  it "fills in the owning rep's booking link" do
    lead = Lead.create!(company_id: company.id, first_name: 'A', last_name: 'B',
                        owner_id: make_rep(booking_url: 'https://calendly.com/owner-rep').id)

    expect(render(lead)).to eq('<a href="https://calendly.com/owner-rep">Book here</a>')
  end

  it 'leaves nothing literal when the lead has no owner' do
    lead = Lead.create!(company_id: company.id, first_name: 'A', last_name: 'B')

    expect(render(lead)).to eq('<a href="">Book here</a>')
  end
end
