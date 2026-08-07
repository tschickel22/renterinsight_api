# frozen_string_literal: true

# Creates a general-purpose "Contact Us" intake form for a company that has none.
#
# Websites::DefaultLeadForm picks the most general-looking active form for a
# site's contact block. On the demo lot every active form is campaign-specific
# ("Google Test", "Facebook Lead Intake", "New Home Sales Special — ..."), so
# the best available answer is still somebody else's marketing sitting on a
# prospect's preview. The right fix is for the lot to own a plain contact form.
#
# Deliberately a task rather than something the resolver creates on demand:
# rendering a page must not write records, and a form that appears by itself is
# one nobody knows to maintain.
#
#   bin/rails 'intake:ensure_contact_form[14]'          # dry run
#   bin/rails 'intake:ensure_contact_form[14]' APPLY=1  # create it
namespace :intake do
  desc 'Create a general Contact Us intake form for COMPANY_ID if none exists (APPLY=1 to write)'
  task :ensure_contact_form, [:company_id] => :environment do |_t, args|
    company_id = args[:company_id].presence || ENV['COMPANY_ID'].presence
    abort 'Pass a company id: bin/rails \'intake:ensure_contact_form[14]\'' if company_id.blank?

    company = Company.find_by(id: company_id)
    abort "Company #{company_id} not found" if company.nil?

    apply = ENV['APPLY'].present?
    puts "company: #{company.id} #{company.name}"

    existing = Websites::DefaultLeadForm.for(company)
    if existing && Websites::DefaultLeadForm::GENERAL_PURPOSE.match?(existing.name.to_s)
      puts "already has a general contact form: ##{existing.id} #{existing.name}"
      next
    end

    puts(existing ? "current best match is campaign-shaped: ##{existing.id} #{existing.name}" : 'no usable form')

    # leadField values are the ones already in use across real forms, so
    # submissions map onto a Lead the same way every other form does.
    schema = [
      { 'name' => 'First Name', 'label' => 'First Name', 'type' => 'text',
        'required' => true,  'order' => 1, 'leadField' => 'first_name' },
      { 'name' => 'Last Name',  'label' => 'Last Name',  'type' => 'text',
        'required' => true,  'order' => 2, 'leadField' => 'last_name' },
      { 'name' => 'Email',      'label' => 'Email',      'type' => 'email',
        'required' => true,  'order' => 3, 'leadField' => 'email' },
      { 'name' => 'Phone',      'label' => 'Phone',      'type' => 'tel',
        'required' => false, 'order' => 4, 'leadField' => 'phone' },
      { 'name' => 'Message',    'label' => 'How can we help?', 'type' => 'textarea',
        'required' => false, 'order' => 5, 'leadField' => 'notes' }
    ].map { |f| f.merge('id' => SecureRandom.uuid, 'isActive' => true, 'placeholder' => '') }

    unless apply
      puts 'would create "Contact Us" with: ' + schema.map { |f| f['label'] }.join(', ')
      puts 'MODE: dry run (pass APPLY=1 to write)'
      next
    end

    form = company.intake_forms.create!(
      name: 'Contact Us',
      description: 'General enquiries from the website.',
      schema: schema,
      is_active: true,
      auto_create_lead: true,
      auto_create_activity: true,
      submit_button_text: 'Send Message',
      thank_you_message: 'Thanks for reaching out. We will get back to you shortly.',
      field_mappings: schema.to_h { |f| [f['name'], f['leadField']] }
    )

    puts "created form ##{form.id} (public_id #{form.public_id})"
    puts "DefaultLeadForm now resolves to: ##{Websites::DefaultLeadForm.for(company.reload)&.id}"
  end
end
