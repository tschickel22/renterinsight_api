# frozen_string_literal: true

# This file should contain all the record creation needed to seed the database with its default values.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).

puts "🌱 Starting seed..."

# Load lead sources
load Rails.root.join('db', 'seeds', 'sources.rb')

# Load company user invitation templates
load Rails.root.join('db', 'seeds', 'company_user_invitation_templates.rb')

puts "✨ Seed completed!"
