# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db/migrate/20261009100000_normalize_agreement_content_types.rb')

# An agreement is pdf_upload or rich_text, the builder's two words; a template
# says upload or editor. Copying the template's word across opened PDF
# agreements in the text editor, whose autosave then turned them into text.
RSpec.describe 'Agreement content type' do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:pdf_template) { company.agreement_templates.create!(name: 'PDF form', status: 'active', template_type: 'upload', document_url: 's3://bucket/form.pdf') }
  let(:text_template) { company.agreement_templates.create!(name: 'Text form', status: 'active', template_type: 'editor', content: '<p>Terms</p>') }
  let(:user) { User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'S', password: 'Pass1234!', company_id: company.id, role: 'company_admin') }

  def agreement(**attrs) = company.agreements.create!({ title: 'A', status: 'draft' }.merge(attrs))

  it 'saves the builder words, whatever it was given' do
    expect(agreement(content_type: 'upload', document_url: 's3://bucket/a.pdf').content_type).to eq('pdf_upload')
    expect(agreement(content_type: 'upload', content: '<p>Hi</p>').content_type).to eq('rich_text')
    expect(agreement(content_type: 'editor').content_type).to eq('rich_text')
    expect(agreement(content_type: 'upload', agreement_template: text_template).content_type).to eq('rich_text')
    expect(agreement(content_type: 'upload').content_type).to eq('pdf_upload')
    expect(agreement(content_type: 'rich_text').content_type).to eq('rich_text')
    expect(agreement(content_type: 'rich_text', content: '<p>Hi</p>', document_url: 's3://bucket/a.pdf').content_type).to eq('rich_text')

    # The editor's autosave of a PDF agreement: no text, the PDF still on it.
    pdf = agreement(content_type: 'pdf_upload', document_url: 's3://bucket/a.pdf')
    pdf.update!(content_type: 'rich_text')
    expect(pdf.reload.content_type).to eq('pdf_upload')
  end

  it 'makes an agreement from a template in the builder words' do
    service = AgreementService.new(company)
    expect(service.create_from_template(pdf_template, {}, user).content_type).to eq('pdf_upload')
    expect(service.create_from_template(text_template, {}, user).content_type).to eq('rich_text')
  end

  it 'repairs the rows already written' do
    rows = {
      pdf: agreement(content_type: 'pdf_upload', document_url: 's3://bucket/a.pdf'),
      autosaved: agreement(content_type: 'pdf_upload', document_url: 's3://bucket/b.pdf'),
      text: agreement(content_type: 'rich_text', content: '<p>Hi</p>'),
      from_editor: agreement(content_type: 'rich_text', agreement_template: text_template),
      bare: agreement(content_type: 'pdf_upload')
    }
    rows[:autosaved].update_columns(content_type: 'rich_text')
    rows[:text].update_columns(content_type: 'upload')
    rows[:from_editor].update_columns(content_type: 'upload')
    rows[:bare].update_columns(content_type: 'upload')

    ActiveRecord::Migration.suppress_messages { NormalizeAgreementContentTypes.new.up }
    expect(rows.transform_values { |a| a.reload.content_type }).to eq(
      pdf: 'pdf_upload', autosaved: 'pdf_upload', text: 'rich_text', from_editor: 'rich_text', bare: 'pdf_upload'
    )
  end
end
