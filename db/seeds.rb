# frozen_string_literal: true

# This file should contain all the record creation needed to seed the database with its default values.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).

puts "🌱 Starting seed..."

# Load RBAC system (resources, actions, scopes, roles, permissions)
load Rails.root.join('db', 'seeds', 'rbac_system_seed.rb')

# Load lead sources
load Rails.root.join('db', 'seeds', 'sources.rb')

# Load company user invitation templates
load Rails.root.join('db', 'seeds', 'company_user_invitation_templates.rb')

# Load tenant invitation templates
load Rails.root.join('db', 'seeds', 'tenant_invitation_templates.rb')

# Load brochure templates
load Rails.root.join('db', 'seeds', 'brochure_templates.rb')

# Load payment settings
load Rails.root.join('db', 'seeds', 'payment_settings.rb')

# Load subscription plans
load Rails.root.join('db', 'seeds', 'subscription_plans.rb')

puts "✨ Seed completed!"
