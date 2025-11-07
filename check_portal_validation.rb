#!/usr/bin/env ruby
# frozen_string_literal: true

puts "=" * 80
puts "🔍 CHECKING PORTAL USER INVITATION REQUIREMENTS"
puts "=" * 80

# Check what validations exist for portal_user invitations
puts "\n1️⃣ INVITATION MODEL VALIDATIONS:"
invitation = Invitation.new(
  invitation_type: 'portal_user',
  email: 'test@example.com',
  invited_by: User.first,
  delivery_method: 'email'
)

if invitation.valid?
  puts "   ✅ Basic portal_user invitation is valid"
else
  puts "   ❌ Validation errors:"
  invitation.errors.full_messages.each do |error|
    puts "      - #{error}"
  end
end

# Check if company is required
puts "\n2️⃣ CHECKING COMPANY REQUIREMENT:"
company = Company.first
invitation_with_company = Invitation.new(
  invitation_type: 'portal_user',
  email: 'test@example.com',
  invited_by: User.first,
  company: company,
  delivery_method: 'email'
)

if invitation_with_company.valid?
  puts "   ✅ Portal user invitation with company is valid"
else
  puts "   ❌ Validation errors with company:"
  invitation_with_company.errors.full_messages.each do |error|
    puts "      - #{error}"
  end
end

# Try to create via InvitationService
puts "\n3️⃣ TESTING INVITATIONSERVICE.CREATE_INVITATION:"
service = InvitationService.new(invited_by: User.first, company: company)

result = service.create_invitation(
  invitation_type: 'portal_user',
  email: 'portaltest@example.com',
  phone: '+13035551234',
  recipient_name: 'Portal Test',
  delivery_method: 'email'
)

if result[:success]
  puts "   ✅ Portal invitation created successfully!"
else
  puts "   ❌ Portal invitation failed:"
  puts "      Error: #{result[:error]}"
end

puts "\n" + "=" * 80
