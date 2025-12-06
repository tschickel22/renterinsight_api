# frozen_string_literal: true

class SeedWarrantyEmailTemplates < ActiveRecord::Migration[8.0]
  def up
    # Update or create warranty email templates
    
    # 1. Warranty Submitted to Manufacturer
    template = CommunicationTemplate.find_or_initialize_by(
      template_type: 'warranty_submitted_to_manufacturer',
      company_id: nil
    )
    
    template.assign_attributes(
      name: 'Warranty Claim Submitted to Manufacturer',
      channel: 'email',
      subject: 'New Warranty Claim #{{claim_number}} from {{company_name}}',
      body: <<~'BODY',
          Dear {{manufacturer_name}},

          A new warranty claim has been submitted for your review.

          CLAIM DETAILS:
          Claim Number: {{claim_number}}
          Submitted Date: {{claim_date}}
          Dealer: {{company_name}}
          Dealer Code: {{dealer_code}}
          Estimated Amount: {{estimated_amount}}

          SERVICE TICKET INFORMATION:
          Ticket #{{ticket_number}}
          Vehicle: {{vehicle_info}}
          Customer: {{customer_name}}
          Description: {{ticket_description}}

          PARTS REQUIRED:
          {{parts_list}}

          LABOR DETAILS:
          {{labor_details}}

          NOTES FROM DEALER:
          {{claim_notes}}

          ATTACHMENTS:
          {{photos_count}} photos/documents included with this claim

          REVIEW AND RESPOND:
          Please review the claim details and provide your decision at:
          {{warranty_link}}

          You can:
          • Approve the claim and specify the approved amount
          • Request more information or photos
          • Deny the claim with a reason

          Questions? Contact us:
          {{company_name}}
          Phone: {{company_phone}}
          Email: {{company_email}}

          This is an automated notification from {{company_name}}'s warranty management system.
        BODY
      is_active: true,
      is_default: true
    )
    
    template.save!
    puts "✅ Updated/created: warranty_submitted_to_manufacturer"
    
    # 2. Manufacturer Responded to Company
    template = CommunicationTemplate.find_or_initialize_by(
      template_type: 'warranty_manufacturer_responded',
      company_id: nil
    )
    
    template.assign_attributes(
      name: 'Manufacturer Response to Warranty Claim',
      channel: 'email',
      subject: 'Response Received: Warranty Claim #{{claim_number}}',
      body: <<~'BODY',
          A response has been received for warranty claim #{{claim_number}}.

          CLAIM DETAILS:
          Claim Number: {{claim_number}}
          Original Submission: {{claim_date}}
          Manufacturer: {{manufacturer_name}}
          Original Amount: {{estimated_amount}}

          MANUFACTURER RESPONSE:
          Status: {{response_status}}
          Response Date: {{response_date}}
          {{approved_amount_section}}

          RESPONSE NOTES:
          {{manufacturer_response}}

          DENIAL REASON (if denied):
          {{denial_reason}}

          VIEW CLAIM:
          {{claim_admin_link}}

          SERVICE TICKET DETAILS:
          Ticket #{{ticket_number}}
          Customer: {{customer_name}}
          Vehicle: {{vehicle_info}}

          Next steps will depend on the manufacturer's response. Please review and take appropriate action.

          ---
          {{company_name}} Warranty Management System
        BODY
      is_active: true,
      is_default: true
    )
    
    template.save!
    puts "✅ Updated/created: warranty_manufacturer_responded"
    
    # 3. Warranty Approved - Client Notification
    template = CommunicationTemplate.find_or_initialize_by(
      template_type: 'warranty_approved_client',
      company_id: nil
    )
    
    template.assign_attributes(
      name: 'Warranty Claim Approved - Client Notification',
      channel: 'email',
      subject: 'Good News! Your Warranty Claim Has Been Approved',
      body: <<~'BODY',
          Dear {{customer_name}},

          Great news! Your warranty claim for {{vehicle_info}} has been approved by the manufacturer.

          CLAIM DETAILS:
          Claim Number: {{claim_number}}
          Approval Date: {{response_date}}
          {{approved_amount_section}}
          Service Ticket: #{{ticket_number}}

          WHAT THIS MEANS:
          The manufacturer has agreed to cover the warranty repairs. {{client_copay_section}}

          WHAT HAPPENS NEXT:
          {{next_steps}}

          We'll keep you updated on the repair progress. If you have any questions, please don't hesitate to reach out.

          View your service ticket status online:
          {{portal_link}}

          Thank you for choosing {{company_name}}!

          Best regards,
          {{company_name}}
          {{company_phone}}
          {{company_email}}
        BODY
      is_active: true,
      is_default: true
    )
    
    template.save!
    puts "✅ Updated/created: warranty_approved_client"
    
    # 4. Warranty Denied - Client Notification
    template = CommunicationTemplate.find_or_initialize_by(
      template_type: 'warranty_denied_client',
      company_id: nil
    )
    
    template.assign_attributes(
      name: 'Warranty Claim Denied - Client Notification',
      channel: 'email',
      subject: 'Update on Your Warranty Claim #{{claim_number}}',
      body: <<~'BODY',
          Dear {{customer_name}},

          We wanted to update you on the warranty claim we submitted for your {{vehicle_info}}.

          CLAIM DETAILS:
          Claim Number: {{claim_number}}
          Response Date: {{response_date}}
          Manufacturer: {{manufacturer_name}}

          MANUFACTURER'S RESPONSE:
          Unfortunately, the manufacturer has declined to cover this repair under warranty.

          REASON PROVIDED:
          {{denial_reason}}

          YOUR OPTIONS:
          We understand this may be disappointing. Here are your next steps:

          1. Review the denial reason to understand the manufacturer's decision
          2. Contact us to discuss alternative repair options
          3. We can help you explore if this might be eligible for resubmission with additional documentation

          {{customer_responsibility_section}}

          We're here to help you determine the best path forward. Please contact us to discuss your options.

          View your service ticket:
          {{portal_link}}

          Questions? We're Here to Help:
          {{company_name}}
          Phone: {{company_phone}}
          Email: {{company_email}}

          We appreciate your business and are committed to taking care of your {{vehicle_info}}.

          Best regards,
          {{company_name}} Service Team
        BODY
      is_active: true,
      is_default: true
    )
    
    template.save!
    puts "✅ Updated/created: warranty_denied_client"
    
    puts "\n✅ Warranty email templates seeded successfully"
  end

  def down
    # Remove the seeded templates
    CommunicationTemplate.where(
      template_type: [
        'warranty_submitted_to_manufacturer',
        'warranty_manufacturer_responded',
        'warranty_approved_client',
        'warranty_denied_client'
      ],
      company_id: nil
    ).destroy_all

    puts "🗑️  Warranty email templates removed"
  end
end
