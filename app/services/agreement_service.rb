class AgreementService
  def initialize(company)
    @company = company
  end

  # Create agreement from template
  def create_from_template(template, params, user)
    agreement = @company.agreements.build(
      title: params[:title] || template.name,
      description: params[:description] || template.description,
      category: template.category,
      agreement_template: template,
      content_type: template.template_type,
      content: template.content,
      document_url: template.document_url,
      field_placements: template.field_placements,
      merge_field_values: params[:merge_field_values] || {},
      prepared_by: user,
      expires_at: params[:expires_at] || 30.days.from_now,
      reminder_frequency_days: params[:reminder_frequency_days] || 3,
      location_id: params[:location_id] || Current.location_id
    )

    # Copy default signers from template
    if template.default_signers.present?
      template.default_signers.each do |signer_def|
        agreement.agreement_signers.build(
          role: signer_def['role'] || 'signer',
          signing_order: signer_def['signing_order'] || 1,
          name: signer_def['name'] || 'TBD',
          email: signer_def['email'] || 'tbd@example.com'
        )
      end
    end

    agreement.save!
    agreement
  end

  # Resolve merge field values from entity IDs
  def resolve_merge_fields(agreement, entity_ids = {})
    values = {}

    # Contact fields
    if entity_ids[:contact_id].present?
      contact = @company.contacts.find_by(id: entity_ids[:contact_id])
      if contact
        values.merge!(
          'contact.first_name' => contact.first_name,
          'contact.last_name' => contact.last_name,
          'contact.full_name' => "#{contact.first_name} #{contact.last_name}".strip,
          'contact.email' => contact.email,
          'contact.phone' => contact.phone,
          'contact.title' => contact.try(:title),
          'contact.company_name' => contact.try(:company_name),
          'contact.street' => contact.try(:street) || contact.try(:address),
          'contact.city' => contact.try(:city),
          'contact.state' => contact.try(:state),
          'contact.zip' => contact.try(:zip)
        )
      end
    end

    # Company fields
    values.merge!(
      'company.name' => @company.name,
      'company.phone' => @company.try(:phone),
      'company.email' => @company.try(:email),
      'company.website' => @company.try(:website),
      'company.street' => @company.try(:street),
      'company.city' => @company.try(:city),
      'company.state' => @company.try(:state),
      'company.zip' => @company.try(:zip)
    )

    # Location fields
    if entity_ids[:location_id].present?
      location = @company.locations.find_by(id: entity_ids[:location_id])
      if location
        values.merge!(
          'location.name' => location.name,
          'location.code' => location.try(:code),
          'location.phone' => location.try(:phone),
          'location.email' => location.try(:email),
          'location.street' => location.try(:street),
          'location.city' => location.try(:city),
          'location.state' => location.try(:state),
          'location.zip' => location.try(:zip)
        )
      end
    end

    # Vehicle fields
    if entity_ids[:vehicle_id].present?
      vehicle = @company.vehicles.find_by(id: entity_ids[:vehicle_id])
      if vehicle
        values.merge!(
          'vehicle.year' => vehicle.try(:year)&.to_s,
          'vehicle.make' => vehicle.try(:make),
          'vehicle.model' => vehicle.try(:model),
          'vehicle.vin' => vehicle.try(:vin),
          'vehicle.stock_number' => vehicle.try(:stock_number),
          'vehicle.price' => vehicle.try(:sale_price)&.to_s || vehicle.try(:price)&.to_s,
          'vehicle.mileage' => vehicle.try(:mileage)&.to_s,
          'vehicle.color' => vehicle.try(:exterior_color) || vehicle.try(:color)
        )
      end
    end

    # Quote fields
    if entity_ids[:quote_id].present?
      quote = @company.quotes.find_by(id: entity_ids[:quote_id])
      if quote
        values.merge!(
          'quote.number' => quote.try(:quote_number),
          'quote.subtotal' => quote.try(:subtotal)&.to_s,
          'quote.tax' => quote.try(:tax_amount)&.to_s || quote.try(:tax)&.to_s,
          'quote.total' => quote.try(:total)&.to_s || quote.try(:total_amount)&.to_s,
          'quote.valid_until' => quote.try(:valid_until)&.strftime('%m/%d/%Y')
        )
      end
    end

    # Deal fields
    if entity_ids[:deal_id].present?
      deal = @company.deals.find_by(id: entity_ids[:deal_id])
      if deal
        values.merge!(
          'deal.title' => deal.try(:title) || deal.try(:name),
          'deal.value' => deal.try(:value)&.to_s || deal.try(:amount)&.to_s,
          'deal.stage' => deal.try(:stage),
          'deal.expected_close_date' => deal.try(:expected_close_date)&.strftime('%m/%d/%Y')
        )
      end
    end

    # Account fields
    if entity_ids[:account_id].present?
      account = @company.accounts.find_by(id: entity_ids[:account_id])
      if account
        values.merge!(
          'account.name' => account.name,
          'account.account_number' => account.try(:account_number),
          'account.type' => account.try(:account_type),
          'account.industry' => account.try(:industry),
          'account.phone' => account.try(:phone),
          'account.email' => account.try(:email)
        )
      end
    end

    # Property fields
    if entity_ids[:property_id].present?
      property = @company.properties.find_by(id: entity_ids[:property_id])
      if property
        values.merge!(
          'property.name' => property.name,
          'property.street' => property.try(:street),
          'property.city' => property.try(:city),
          'property.state' => property.try(:state),
          'property.zip' => property.try(:zip),
          'property.type' => property.try(:property_type),
          'property.units_count' => property.try(:units)&.count&.to_s
        )
      end
    end

    # Agreement fields (self-referencing)
    values.merge!(
      'agreement.number' => agreement.agreement_number,
      'agreement.title' => agreement.title,
      'agreement.date' => agreement.created_at&.strftime('%m/%d/%Y'),
      'agreement.expiry_date' => agreement.expires_at&.strftime('%m/%d/%Y')
    )

    # Current date
    values['today.date'] = Date.current.strftime('%m/%d/%Y')
    values['today.year'] = Date.current.year.to_s

    # Clean nil values
    values.compact!
    values
  end

  # Get available merge field definitions
  def self.available_merge_fields
    {
      contact: [
        { key: 'contact.first_name', label: 'First Name', type: 'text' },
        { key: 'contact.last_name', label: 'Last Name', type: 'text' },
        { key: 'contact.full_name', label: 'Full Name', type: 'text' },
        { key: 'contact.email', label: 'Email', type: 'text' },
        { key: 'contact.phone', label: 'Phone', type: 'text' },
        { key: 'contact.title', label: 'Title', type: 'text' },
        { key: 'contact.company_name', label: 'Company', type: 'text' },
        { key: 'contact.street', label: 'Street Address', type: 'text' },
        { key: 'contact.city', label: 'City', type: 'text' },
        { key: 'contact.state', label: 'State', type: 'text' },
        { key: 'contact.zip', label: 'ZIP Code', type: 'text' }
      ],
      company: [
        { key: 'company.name', label: 'Company Name', type: 'text' },
        { key: 'company.phone', label: 'Phone', type: 'text' },
        { key: 'company.email', label: 'Email', type: 'text' },
        { key: 'company.website', label: 'Website', type: 'text' },
        { key: 'company.street', label: 'Street', type: 'text' },
        { key: 'company.city', label: 'City', type: 'text' },
        { key: 'company.state', label: 'State', type: 'text' },
        { key: 'company.zip', label: 'ZIP', type: 'text' }
      ],
      location: [
        { key: 'location.name', label: 'Location Name', type: 'text' },
        { key: 'location.code', label: 'Code', type: 'text' },
        { key: 'location.phone', label: 'Phone', type: 'text' },
        { key: 'location.email', label: 'Email', type: 'text' },
        { key: 'location.street', label: 'Street', type: 'text' },
        { key: 'location.city', label: 'City', type: 'text' },
        { key: 'location.state', label: 'State', type: 'text' },
        { key: 'location.zip', label: 'ZIP', type: 'text' }
      ],
      vehicle: [
        { key: 'vehicle.year', label: 'Year', type: 'text' },
        { key: 'vehicle.make', label: 'Make', type: 'text' },
        { key: 'vehicle.model', label: 'Model', type: 'text' },
        { key: 'vehicle.vin', label: 'VIN', type: 'text' },
        { key: 'vehicle.stock_number', label: 'Stock #', type: 'text' },
        { key: 'vehicle.price', label: 'Price', type: 'currency' },
        { key: 'vehicle.mileage', label: 'Mileage', type: 'text' },
        { key: 'vehicle.color', label: 'Color', type: 'text' }
      ],
      property: [
        { key: 'property.name', label: 'Property Name', type: 'text' },
        { key: 'property.street', label: 'Street', type: 'text' },
        { key: 'property.city', label: 'City', type: 'text' },
        { key: 'property.state', label: 'State', type: 'text' },
        { key: 'property.zip', label: 'ZIP', type: 'text' },
        { key: 'property.type', label: 'Type', type: 'text' },
        { key: 'property.units_count', label: 'Unit Count', type: 'text' }
      ],
      quote: [
        { key: 'quote.number', label: 'Quote Number', type: 'text' },
        { key: 'quote.subtotal', label: 'Subtotal', type: 'currency' },
        { key: 'quote.tax', label: 'Tax', type: 'currency' },
        { key: 'quote.total', label: 'Total', type: 'currency' },
        { key: 'quote.valid_until', label: 'Valid Until', type: 'date' }
      ],
      deal: [
        { key: 'deal.title', label: 'Deal Title', type: 'text' },
        { key: 'deal.value', label: 'Deal Value', type: 'currency' },
        { key: 'deal.stage', label: 'Stage', type: 'text' },
        { key: 'deal.expected_close_date', label: 'Expected Close', type: 'date' }
      ],
      account: [
        { key: 'account.name', label: 'Account Name', type: 'text' },
        { key: 'account.account_number', label: 'Account Number', type: 'text' },
        { key: 'account.type', label: 'Type', type: 'text' },
        { key: 'account.industry', label: 'Industry', type: 'text' },
        { key: 'account.phone', label: 'Phone', type: 'text' },
        { key: 'account.email', label: 'Email', type: 'text' }
      ],
      signer: [
        { key: 'signer.name', label: 'Signer Name', type: 'text' },
        { key: 'signer.email', label: 'Signer Email', type: 'text' },
        { key: 'signer.signature', label: 'Signature', type: 'signature' },
        { key: 'signer.initials', label: 'Initials', type: 'initials' },
        { key: 'signer.signed_date', label: 'Date Signed', type: 'date' }
      ],
      agreement: [
        { key: 'agreement.number', label: 'Agreement Number', type: 'text' },
        { key: 'agreement.title', label: 'Title', type: 'text' },
        { key: 'agreement.date', label: 'Agreement Date', type: 'date' },
        { key: 'agreement.expiry_date', label: 'Expiry Date', type: 'date' }
      ],
      custom: [
        { key: 'custom.text_field', label: 'Custom Text', type: 'text_input' },
        { key: 'custom.date_field', label: 'Custom Date', type: 'date_input' },
        { key: 'custom.checkbox', label: 'Custom Checkbox', type: 'checkbox' },
        { key: 'today.date', label: "Today's Date", type: 'date' },
        { key: 'today.year', label: 'Current Year', type: 'text' }
      ]
    }
  end
end
