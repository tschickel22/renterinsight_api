# frozen_string_literal: true

class AddWarrantyTemplateTypes < ActiveRecord::Migration[8.0]
  def up
    # Add new warranty template types to CommunicationTemplate model
    # Using raw SQL with dollar-quoted strings to avoid Ruby interpolation issues
    
    # Template 1: Warranty Claim Submitted to Manufacturer
    execute(<<-'SQL')
      INSERT INTO communication_templates (
        name, channel, template_type, subject, body, is_active, is_default, company_id, created_at, updated_at
      ) VALUES (
        'Warranty Claim Submitted to Manufacturer',
        'email',
        'warranty_submitted_to_manufacturer',
        'Warranty Claim #{{claim_number}} - {{company_name}}',
        'Dear {{manufacturer_name}},

We are submitting a warranty claim for your review:

Claim Number: {{claim_number}}
Vehicle/Unit: {{vehicle_info}}
Customer: {{customer_name}}
Claim Date: {{claim_date}}

Estimated Amount: ${{estimated_amount}}

Parts Required:
{{parts_list}}

Labor Details:
{{labor_details}}

Additional Notes:
{{claim_notes}}

Please review this claim at your earliest convenience by clicking the link below:
{{warranty_link}}

You can approve, deny, or request additional information directly through the link.

Attached: {{photos_count}} photo(s) and {{documents_count}} document(s)

Thank you,
{{company_name}}
{{company_phone}}
{{company_email}}',
        true, true, NULL, NOW(), NOW()
      ) ON CONFLICT DO NOTHING;
    SQL
    
    # Template 2: Warranty Response Received
    execute(<<-'SQL')
      INSERT INTO communication_templates (
        name, channel, template_type, subject, body, is_active, is_default, company_id, created_at, updated_at
      ) VALUES (
        'Warranty Response Received',
        'email',
        'warranty_manufacturer_responded',
        'Warranty Claim #{{claim_number}} - Manufacturer Response',
        'Hello {{company_user_name}},

The manufacturer has responded to warranty claim #{{claim_number}}.

Status: {{response_status}}
Response Date: {{response_date}}

{{manufacturer_response}}

{{approved_amount_section}}

View full claim details: {{claim_admin_link}}

This is an automated notification.',
        true, true, NULL, NOW(), NOW()
      ) ON CONFLICT DO NOTHING;
    SQL
    
    # Template 3: Warranty Approved - Client Notification
    execute(<<-'SQL')
      INSERT INTO communication_templates (
        name, channel, template_type, subject, body, is_active, is_default, company_id, created_at, updated_at
      ) VALUES (
        'Warranty Approved - Client Notification',
        'email',
        'warranty_approved_client',
        'Good News! Warranty Claim Approved - Service Ticket #{{ticket_number}}',
        'Dear {{customer_name}},

We have good news regarding your service request!

The manufacturer has approved the warranty claim for:
{{vehicle_info}}

Service Issue: {{ticket_description}}

Approved Amount: ${{approved_amount}}
{{client_copay_section}}

What happens next:
{{next_steps}}

You can view the status of your service ticket anytime in your client portal:
{{portal_link}}

If you have any questions, please contact us.

Thank you,
{{company_name}}
{{company_phone}}',
        true, true, NULL, NOW(), NOW()
      ) ON CONFLICT DO NOTHING;
    SQL
    
    # Template 4: Warranty Denied - Client Notification
    execute(<<-'SQL')
      INSERT INTO communication_templates (
        name, channel, template_type, subject, body, is_active, is_default, company_id, created_at, updated_at
      ) VALUES (
        'Warranty Denied - Client Notification',
        'email',
        'warranty_denied_client',
        'Warranty Claim Update - Service Ticket #{{ticket_number}}',
        'Dear {{customer_name}},

We have received a response from the manufacturer regarding your service request for:
{{vehicle_info}}

Unfortunately, the warranty claim was not approved for the following reason:
{{denial_reason}}

{{customer_responsibility_section}}

We apologize for any inconvenience. If you have questions about this decision, please contact us and we will do our best to assist you.

You can view your service ticket and any invoices in your client portal:
{{portal_link}}

Thank you,
{{company_name}}
{{company_phone}}',
        true, true, NULL, NOW(), NOW()
      ) ON CONFLICT DO NOTHING;
    SQL
  end
  
  def down
    # Remove the seeded warranty templates
    execute <<-SQL
      DELETE FROM communication_templates 
      WHERE template_type IN (
        'warranty_submitted_to_manufacturer',
        'warranty_manufacturer_responded',
        'warranty_approved_client',
        'warranty_denied_client'
      ) AND company_id IS NULL;
    SQL
  end
end
