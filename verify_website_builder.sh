#!/bin/bash
# Website Builder Phase 1 - Verification Script

echo "=========================================="
echo "Website Builder Phase 1 - Verification"
echo "=========================================="
echo ""

echo "✓ Checking Database Tables..."
cd ~/src/renterinsight_api
bin/rails runner "
tables = ['websites', 'website_pages', 'website_media', 'blog_categories', 'blog_posts', 'blog_posts_categories', 'website_versions']
tables.each do |table|
  exists = ActiveRecord::Base.connection.table_exists?(table)
  puts exists ? \"  ✅ #{table}\" : \"  ❌ #{table} MISSING\"
end
"

echo ""
echo "✓ Checking Models..."
bin/rails runner "
models = ['Website', 'WebsitePage', 'WebsiteMedia', 'BlogCategory', 'BlogPost', 'WebsiteVersion']
models.each do |model|
  begin
    model.constantize
    puts \"  ✅ #{model}\"
  rescue NameError
    puts \"  ❌ #{model} MISSING\"
  end
end
"

echo ""
echo "✓ Checking RBAC Permissions..."
bin/rails runner "
resource = Resource.find_by(key: 'websites')
if resource
  puts \"  ✅ Resource: #{resource.name} (ID: #{resource.id})\"
  role = Role.find_by(key: 'company_admin')
  perms = RolePermission.where(role: role, resource: resource).count
  puts \"  ✅ Permissions: #{perms} actions granted\"
else
  puts \"  ❌ Resource 'websites' not found\"
end
"

echo ""
echo "✓ Checking Routes..."
bin/rails runner "
routes = Rails.application.routes.routes.map(&:path).grep(/websites/)
puts \"  ✅ Found #{routes.count} website routes\"
"

echo ""
echo "=========================================="
echo "Phase 1 Verification Complete!"
echo "=========================================="
