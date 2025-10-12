# Run this in Rails console to create test data for Contacts
# rails console
# load 'seed_test_contacts.rb'

puts "Creating test data for Contacts..."

# Find or create a company
company = Company.first_or_create!(name: "Test Company")
puts "✓ Company: #{company.name}"

# Find or create test accounts
accounts = []
5.times do |i|
  account = Account.find_or_create_by!(name: "Test Account #{i + 1}") do |a|
    a.status = 'active'
    a.company = company
    a.email = "account#{i + 1}@test.com"
    a.phone = "555-010#{i}"
    a.account_type = ['prospect', 'customer', 'vendor'].sample
  end
  accounts << account
  puts "✓ Account: #{account.name}"
end

# Create departments and titles
departments = ['Sales', 'Marketing', 'Support', 'Engineering', 'Management']
titles = ['Manager', 'Director', 'Specialist', 'Associate', 'VP', 'Coordinator']

# Create test contacts
contact_count = 0
accounts.each do |account|
  # Create 3-5 contacts per account
  rand(3..5).times do |i|
    first_names = ['John', 'Jane', 'Michael', 'Sarah', 'David', 'Emily', 'James', 'Lisa']
    last_names = ['Smith', 'Johnson', 'Williams', 'Brown', 'Jones', 'Garcia', 'Miller', 'Davis']
    
    first_name = first_names.sample
    last_name = last_names.sample
    
    contact = Contact.find_or_create_by!(
      account: account,
      first_name: first_name,
      last_name: last_name
    ) do |c|
      c.email = "#{first_name.downcase}.#{last_name.downcase}@test.com"
      c.phone = "555-#{rand(1000..9999)}"
      c.title = titles.sample
      c.department = departments.sample
      c.is_primary = (i == 0) # First contact is primary
      c.notes = "Test contact created for #{account.name}"
      c.company = company
    end
    
    # Add some tags
    if contact.persisted?
      ['VIP', 'Decision Maker', 'Technical', 'Finance'].sample(rand(0..2)).each do |tag_name|
        tag = Tag.find_or_create_by!(name: tag_name) do |t|
          t.color = ['#3B82F6', '#10B981', '#F59E0B', '#EF4444', '#8B5CF6'].sample
        end
        
        unless contact.tags.include?(tag)
          contact.tags << tag
        end
      end
      
      contact_count += 1
      puts "  ✓ Contact: #{contact.full_name} (#{contact.title})"
    end
  end
end

# Create some unassigned contacts (not linked to any account)
puts "\nCreating unassigned contacts..."
unassigned_account = Account.find_or_create_by!(name: "Unassigned Contacts") do |a|
  a.status = 'active'
  a.company = company
  a.account_type = 'prospect'
end

3.times do |i|
  first_names = ['Alex', 'Jordan', 'Taylor', 'Casey', 'Morgan']
  last_names = ['Anderson', 'Thomas', 'Jackson', 'White', 'Harris']
  
  first_name = first_names.sample
  last_name = last_names.sample
  
  contact = Contact.find_or_create_by!(
    account: unassigned_account,
    first_name: first_name,
    last_name: last_name
  ) do |c|
    c.email = "#{first_name.downcase}.#{last_name.downcase}@prospect.com"
    c.phone = "555-#{rand(1000..9999)}"
    c.title = titles.sample
    c.department = departments.sample
    c.notes = "Unassigned prospect contact"
    c.company = company
  end
  
  contact_count += 1 if contact.persisted?
  puts "  ✓ Unassigned Contact: #{contact.full_name}"
end

puts "\n" + "=" * 50
puts "Test data creation complete!"
puts "=" * 50
puts "Created:"
puts "  - #{Company.count} company"
puts "  - #{accounts.count} accounts"
puts "  - #{contact_count} contacts"
puts "  - #{Tag.where(name: ['VIP', 'Decision Maker', 'Technical', 'Finance']).count} tags"
puts "\nYou can now test the Contacts module!"
puts "\nTo view contacts:"
puts "  Contact.all"
puts "\nTo view contacts by account:"
puts "  Account.first.contacts"
puts "\nTo clean up test data later:"
puts "  Contact.where('email LIKE ?', '%@test.com').destroy_all"
puts "  Contact.where('email LIKE ?', '%@prospect.com').destroy_all"
