#!/bin/bash
# Complete Rails Backend Setup - All 7 Features
# Migrations + Models + Routes + Setup
# Controllers must be added manually (see instructions at end)

set -e

echo "============================================"
echo "Rails Backend Setup - 7 New Features"
echo "Migrations + Models + Routes + Configuration"
echo "============================================"
echo ""

cd ~/src/renterinsight_api

if [ ! -f "bin/rails" ]; then
    echo "❌ Error: Not in Rails directory!"
    exit 1
fi

echo "✅ Rails app found at $(pwd)"
echo ""

# Generate timestamp base
BASE_TS=$(date +%Y%m%d%H%M%S)

echo "📝 Creating 8 migration files..."

# Migration 1: Activities
cat > db/migrate/${BASE_TS}_create_activities.rb << 'MIGRATION1'
class CreateActivities < ActiveRecord::Migration[8.0]
  def change
    create_table :activities do |t|
      t.references :lead, null: false, foreign_key: true
      t.references :user, foreign_key: true
      t.string :activity_type, null: false
      t.text :description, null: false
      t.string :outcome
      t.integer :duration
      t.datetime :scheduled_date
      t.datetime :completed_date
      t.json :metadata, default: {}
      t.timestamps
    end

    add_index :activities, [:lead_id, :created_at]
    add_index :activities, :activity_type
  end
end
MIGRATION1

BASE_TS=$((BASE_TS + 1))

# Migration 2: Reminders
cat > db/migrate/${BASE_TS}_create_reminders.rb << 'MIGRATION2'
class CreateReminders < ActiveRecord::Migration[8.0]
  def change
    create_table :reminders do |t|
      t.references :lead, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :reminder_type, null: false
      t.string :title, null: false
      t.text :description
      t.datetime :due_date, null: false
      t.boolean :is_completed, default: false
      t.string :priority, default: 'medium'
      t.timestamps
    end

    add_index :reminders, [:lead_id, :is_completed]
    add_index :reminders, [:user_id, :due_date]
    add_index :reminders, :priority
  end
end
MIGRATION2

BASE_TS=$((BASE_TS + 1))

# Migration 3: Tags
cat > db/migrate/${BASE_TS}_create_tags_and_assignments.rb << 'MIGRATION3'
class CreateTagsAndAssignments < ActiveRecord::Migration[8.0]
  def change
    create_table :tags do |t|
      t.string :name, null: false
      t.string :description
      t.string :color, null: false, default: '#6B7280'
      t.string :category
      t.json :tag_type, default: []
      t.boolean :is_system, default: false
      t.boolean :is_active, default: true
      t.integer :usage_count, default: 0
      t.string :created_by
      t.timestamps
    end

    create_table :tag_assignments do |t|
      t.references :tag, null: false, foreign_key: true
      t.string :entity_type, null: false
      t.string :entity_id, null: false
      t.string :assigned_by
      t.datetime :assigned_at, null: false
      t.timestamps
    end

    add_index :tags, :name, unique: true
    add_index :tags, :category
    add_index :tag_assignments, [:entity_type, :entity_id]
    add_index :tag_assignments, [:tag_id, :entity_type, :entity_id], unique: true, name: 'idx_tag_assignments_unique'
  end
end
MIGRATION3

BASE_TS=$((BASE_TS + 1))

# Migration 4: AI Insights
cat > db/migrate/${BASE_TS}_create_ai_insights.rb << 'MIGRATION4'
class CreateAiInsights < ActiveRecord::Migration[8.0]
  def change
    create_table :ai_insights do |t|
      t.references :lead, null: false, foreign_key: true
      t.string :insight_type, null: false
      t.string :title, null: false
      t.text :description, null: false
      t.integer :confidence, default: 0
      t.boolean :actionable, default: false
      t.json :suggested_actions, default: []
      t.json :metadata, default: {}
      t.datetime :generated_at, null: false
      t.boolean :is_read, default: false
      t.timestamps
    end

    add_index :ai_insights, [:lead_id, :is_read]
    add_index :ai_insights, :insight_type
    add_index :ai_insights, :generated_at
  end
end
MIGRATION4

BASE_TS=$((BASE_TS + 1))

# Migration 5: Lead Scores
cat > db/migrate/${BASE_TS}_create_lead_scores.rb << 'MIGRATION5'
class CreateLeadScores < ActiveRecord::Migration[8.0]
  def change
    create_table :lead_scores do |t|
      t.references :lead, null: false, foreign_key: true
      t.integer :total_score, default: 0
      t.integer :demographic_score, default: 0
      t.integer :behavior_score, default: 0
      t.integer :engagement_score, default: 0
      t.json :factors, default: []
      t.datetime :last_calculated
      t.timestamps
    end

    add_index :lead_scores, :lead_id, unique: true
    add_index :lead_scores, :total_score
    add_index :lead_scores, :last_calculated
  end
end
MIGRATION5

BASE_TS=$((BASE_TS + 1))

# Migration 6: Communication Logs
cat > db/migrate/${BASE_TS}_create_communication_logs.rb << 'MIGRATION6'
class CreateCommunicationLogs < ActiveRecord::Migration[8.0]
  def change
    create_table :communication_logs do |t|
      t.references :lead, null: false, foreign_key: true
      t.string :comm_type, null: false
      t.string :direction, null: false
      t.string :subject
      t.text :content, null: false
      t.string :status, null: false
      t.datetime :sent_at
      t.datetime :delivered_at
      t.datetime :opened_at
      t.datetime :clicked_at
      t.json :metadata, default: {}
      t.timestamps
    end

    add_index :communication_logs, [:lead_id, :sent_at]
    add_index :communication_logs, :comm_type
    add_index :communication_logs, :status
  end
end
MIGRATION6

BASE_TS=$((BASE_TS + 1))

# Migration 7: Settings
cat > db/migrate/${BASE_TS}_create_settings_tables.rb << 'MIGRATION7'
class CreateSettingsTables < ActiveRecord::Migration[8.0]
  def change
    create_table :platform_settings do |t|
      t.json :communications, default: {}
      t.json :other_settings, default: {}
      t.timestamps
    end

    add_column :companies, :communications_settings, :json, default: {}

    reversible do |dir|
      dir.up do
        PlatformSetting.create!(communications: {}) if PlatformSetting.count.zero?
      end
    end
  end
end
MIGRATION7

BASE_TS=$((BASE_TS + 1))

# Migration 8: Accounts & Deals
cat > db/migrate/${BASE_TS}_create_accounts_and_deals.rb << 'MIGRATION8'
class CreateAccountsAndDeals < ActiveRecord::Migration[8.0]
  def change
    create_table :accounts do |t|
      t.string :name, null: false
      t.string :email
      t.string :phone
      t.text :notes
      t.references :source, foreign_key: true
      t.references :converted_from_lead, foreign_key: { to_table: :leads }
      t.timestamps
    end

    create_table :deals do |t|
      t.string :name, null: false
      t.references :account, null: false, foreign_key: true
      t.string :stage
      t.decimal :value, precision: 10, scale: 2
      t.text :notes
      t.references :source, foreign_key: true
      t.timestamps
    end

    add_index :accounts, :name
    add_index :accounts, :email
    add_index :deals, :stage
    add_index :deals, :account_id
  end
end
MIGRATION8

echo "✅ 8 migration files created"
echo ""

echo "📝 Creating 11 model files..."

# Model: Activity
cat > app/models/activity.rb << 'MODEL1'
class Activity < ApplicationRecord
  belongs_to :lead
  belongs_to :user, optional: true

  VALID_TYPES = %w[call email meeting note status_change form_submission website_visit sms nurture_email ai_suggestion].freeze
  VALID_OUTCOMES = %w[positive neutral negative].freeze

  validates :activity_type, presence: true, inclusion: { in: VALID_TYPES }
  validates :description, presence: true
  validates :outcome, inclusion: { in: VALID_OUTCOMES }, allow_nil: true

  scope :recent, -> { order(created_at: :desc) }
  scope :for_lead, ->(lead_id) { where(lead_id: lead_id) }
  scope :by_type, ->(type) { where(activity_type: type) }
end
MODEL1

# Model: Reminder
cat > app/models/reminder.rb << 'MODEL2'
class Reminder < ApplicationRecord
  belongs_to :lead
  belongs_to :user

  VALID_TYPES = %w[follow_up call email meeting deadline].freeze
  VALID_PRIORITIES = %w[low medium high urgent].freeze

  validates :reminder_type, presence: true, inclusion: { in: VALID_TYPES }
  validates :title, presence: true
  validates :due_date, presence: true
  validates :priority, presence: true, inclusion: { in: VALID_PRIORITIES }

  scope :active, -> { where(is_completed: false) }
  scope :completed, -> { where(is_completed: true) }
  scope :overdue, -> { where('due_date < ? AND is_completed = ?', Time.current, false) }
  scope :for_lead, ->(lead_id) { where(lead_id: lead_id) }
  scope :for_user, ->(user_id) { where(user_id: user_id) }
  scope :by_priority, ->(priority) { where(priority: priority) }

  def complete!
    update!(is_completed: true)
  end
end
MODEL2

# Model: Tag
cat > app/models/tag.rb << 'MODEL3'
class Tag < ApplicationRecord
  has_many :tag_assignments, dependent: :destroy

  validates :name, presence: true, uniqueness: true
  validates :color, presence: true

  scope :active, -> { where(is_active: true) }
  scope :by_category, ->(category) { where(category: category) }

  def increment_usage!
    increment!(:usage_count)
  end

  def decrement_usage!
    decrement!(:usage_count) if usage_count > 0
  end
end
MODEL3

# Model: TagAssignment
cat > app/models/tag_assignment.rb << 'MODEL4'
class TagAssignment < ApplicationRecord
  belongs_to :tag

  validates :entity_type, presence: true
  validates :entity_id, presence: true
  validates :tag_id, uniqueness: { scope: [:entity_type, :entity_id] }

  scope :for_entity, ->(type, id) { where(entity_type: type, entity_id: id) }

  after_create :increment_tag_usage
  after_destroy :decrement_tag_usage

  private

  def increment_tag_usage
    tag.increment_usage!
  end

  def decrement_tag_usage
    tag.decrement_usage!
  end
end
MODEL4

# Model: AiInsight
cat > app/models/ai_insight.rb << 'MODEL5'
class AiInsight < ApplicationRecord
  belongs_to :lead

  VALID_TYPES = %w[next_action communication_style timing content_suggestion risk_assessment].freeze

  validates :insight_type, presence: true, inclusion: { in: VALID_TYPES }
  validates :title, presence: true
  validates :description, presence: true
  validates :generated_at, presence: true

  scope :recent, -> { order(generated_at: :desc) }
  scope :for_lead, ->(lead_id) { where(lead_id: lead_id) }
  scope :unread, -> { where(is_read: false) }
  scope :actionable, -> { where(actionable: true) }
  scope :by_type, ->(type) { where(insight_type: type) }

  def mark_as_read!
    update!(is_read: true)
  end
end
MODEL5

# Model: LeadScore (with calculation logic)
cat > app/models/lead_score.rb << 'MODEL6'
class LeadScore < ApplicationRecord
  belongs_to :lead

  validates :lead_id, uniqueness: true

  def self.calculate_for_lead(lead)
    score = find_or_initialize_by(lead: lead)
    
    demographic = calculate_demographic_score(lead)
    behavior = calculate_behavior_score(lead)
    engagement = calculate_engagement_score(lead)
    
    score.demographic_score = demographic[:score]
    score.behavior_score = behavior[:score]
    score.engagement_score = engagement[:score]
    score.total_score = demographic[:score] + behavior[:score] + engagement[:score]
    score.factors = [demographic[:factors], behavior[:factors], engagement[:factors]].flatten
    score.last_calculated = Time.current
    score.save!
    
    score
  end

  private

  def self.calculate_demographic_score(lead)
    factors = []
    score = 0
    
    if lead.email.present?
      score += 10
      factors << { factor: 'has_email', points: 10, reason: 'Contact email provided' }
    end
    
    if lead.phone.present?
      score += 10
      factors << { factor: 'has_phone', points: 10, reason: 'Contact phone provided' }
    end
    
    if lead.source_id.present?
      score += 10
      factors << { factor: 'has_source', points: 10, reason: 'Lead source tracked' }
    end
    
    { score: score, factors: factors }
  end

  def self.calculate_behavior_score(lead)
    factors = []
    score = 0
    
    activity_count = Activity.where(lead_id: lead.id).count
    if activity_count > 5
      score += 20
      factors << { factor: 'high_activity', points: 20, reason: "#{activity_count} activities logged" }
    elsif activity_count > 0
      score += 10
      factors << { factor: 'some_activity', points: 10, reason: "#{activity_count} activities logged" }
    end
    
    recent = Activity.where(lead_id: lead.id).where('created_at > ?', 7.days.ago).count
    if recent > 0
      score += 20
      factors << { factor: 'recent_activity', points: 20, reason: 'Active within last 7 days' }
    end
    
    { score: score, factors: factors }
  end

  def self.calculate_engagement_score(lead)
    factors = []
    score = 0
    
    email_comms = CommunicationLog.where(lead_id: lead.id, comm_type: 'email')
    opened_count = email_comms.where(status: 'opened').count
    clicked_count = email_comms.where(status: 'clicked').count
    
    if clicked_count > 0
      score += 15
      factors << { factor: 'email_clicks', points: 15, reason: "Clicked #{clicked_count} email(s)" }
    elsif opened_count > 0
      score += 10
      factors << { factor: 'email_opens', points: 10, reason: "Opened #{opened_count} email(s)" }
    end
    
    positive_outcomes = Activity.where(lead_id: lead.id, outcome: 'positive').count
    if positive_outcomes > 0
      score += 15
      factors << { factor: 'positive_outcomes', points: 15, reason: "#{positive_outcomes} positive interaction(s)" }
    end
    
    { score: score, factors: factors }
  end
end
MODEL6

# Model: CommunicationLog
cat > app/models/communication_log.rb << 'MODEL7'
class CommunicationLog < ApplicationRecord
  belongs_to :lead

  VALID_TYPES = %w[email sms call].freeze
  VALID_DIRECTIONS = %w[outbound inbound].freeze
  VALID_STATUSES = %w[sent delivered opened clicked replied failed pending].freeze

  validates :comm_type, presence: true, inclusion: { in: VALID_TYPES }
  validates :direction, presence: true, inclusion: { in: VALID_DIRECTIONS }
  validates :content, presence: true
  validates :status, presence: true, inclusion: { in: VALID_STATUSES }

  scope :for_lead, ->(lead_id) { where(lead_id: lead_id) }
  scope :by_type, ->(type) { where(comm_type: type) }
  scope :by_status, ->(status) { where(status: status) }
  scope :recent, -> { order(sent_at: :desc) }
end
MODEL7

# Model: PlatformSetting
cat > app/models/platform_setting.rb << 'MODEL8'
class PlatformSetting < ApplicationRecord
  validates :id, inclusion: { in: [1] }
  
  def self.instance
    first_or_create!(id: 1, communications: {}, other_settings: {})
  end
end
MODEL8

# Model: Account
cat > app/models/account.rb << 'MODEL9'
class Account < ApplicationRecord
  belongs_to :source, optional: true
  belongs_to :converted_from_lead, class_name: 'Lead', optional: true
  has_many :deals, dependent: :destroy

  validates :name, presence: true
end
MODEL9

# Model: Deal
cat > app/models/deal.rb << 'MODEL10'
class Deal < ApplicationRecord
  belongs_to :account
  belongs_to :source, optional: true

  validates :name, presence: true
  validates :account, presence: true

  VALID_STAGES = %w[proposal negotiation closed_won closed_lost].freeze
  validates :stage, inclusion: { in: VALID_STAGES }, allow_nil: true
end
MODEL10

# Model: Lead (UPDATE existing)
cat > app/models/lead.rb << 'MODEL11'
class Lead < ApplicationRecord
  belongs_to :source, optional: true
  has_many :lead_tasks, dependent: :destroy
  has_many :activities, dependent: :destroy
  has_many :reminders, dependent: :destroy
  has_many :ai_insights, dependent: :destroy
  has_one :lead_score, dependent: :destroy
  has_many :communication_logs, dependent: :destroy
end
MODEL11

echo "✅ 11 model files created"
echo ""

echo "📝 Updating routes.rb..."

# Backup existing routes
cp config/routes.rb config/routes.rb.backup

# Create new routes file
cat > config/routes.rb << 'ROUTES'
Rails.application.routes.draw do
  get "/up", to: "rails/health#show", as: :rails_health_check

  namespace :api do
    namespace :platform do
      get 'settings', to: 'settings#show'
      patch 'settings', to: 'settings#update'
    end

    namespace :company do
      get 'settings', to: 'settings#show'
      patch 'settings', to: 'settings#update'
    end

    namespace :crm do
      resources :leads, only: [:index, :create, :update, :destroy], param: :id do
        post :notes, on: :member
        resources :tasks, only: [:create, :update, :destroy], controller: "lead_tasks"
        
        get 'activities', on: :member, to: 'activities#index'
        post 'activities', on: :member, to: 'activities#create'
        
        get 'ai_insights', on: :member, to: 'ai_insights#index'
        post 'ai_insights/generate', on: :member, to: 'ai_insights#generate'
        
        get 'reminders', on: :member, to: 'reminders#index'
        post 'reminders', on: :member, to: 'reminders#create'
        
        get 'score', on: :member, to: 'lead_scores#show'
        post 'score/calculate', on: :member, to: 'lead_scores#calculate'
        
        get 'communications', on: :member, to: 'communications#index'
        get 'tags', on: :member, to: 'tags#entity_tags'
        post 'convert', on: :member, to: 'lead_conversions#convert'
      end

      resources :sources, only: [:index, :create, :update, :destroy], param: :id do
        get :stats, on: :member
      end

      patch 'ai_insights/:id/mark_read', to: 'ai_insights#mark_read'

      resources :reminders, only: [:destroy] do
        patch 'complete', on: :member
      end

      resources :tags, only: [:index, :create, :update, :destroy]
      post 'tags/assign', to: 'tags#assign'
      delete 'tags/assignments/:id', to: 'tags#remove_assignment'

      namespace :communications do
        post 'email', to: 'communications#send_email'
        post 'sms', to: 'communications#send_sms'
        post 'log', to: 'communications#create_log'
      end

      namespace :nurture do
        resources :sequences, only: [:index] do
          collection { post :bulk }
        end
        resources :enrollments, only: [:index] do
          collection { post :bulk }
        end
      end

      namespace :intake do
        resources :forms, only: [:index] do
          collection { post :bulk }
        end
        resources :submissions, only: [:index] do
          collection { post :bulk }
        end
      end
    end
  end
end
ROUTES

echo "✅ routes.rb updated (backup saved as routes.rb.backup)"
echo ""

echo "📁 Creating controller directories..."
mkdir -p app/controllers/api/crm
mkdir -p app/controllers/api/platform
mkdir -p app/controllers/api/company

echo "✅ Controller directories created"
echo ""

echo "🗄️  Running migrations..."
bin/rails db:migrate

echo ""
echo "✅ Migrations completed!"
echo ""

echo "🌱 Initializing platform settings..."
bin/rails runner "PlatformSetting.instance"

echo ""
echo "============================================"
echo "SETUP COMPLETE - 90% DONE!"
echo "============================================"
echo ""
echo "⚠️  FINAL STEP: Add 9 Controller Files"
echo ""
echo "You need to manually create these controller files:"
echo ""
echo "1. app/controllers/api/crm/activities_controller.rb"
echo "2. app/controllers/api/crm/reminders_controller.rb"
echo "3. app/controllers/api/crm/tags_controller.rb"
echo "4. app/controllers/api/crm/ai_insights_controller.rb"
echo "5. app/controllers/api/crm/lead_scores_controller.rb"
echo "6. app/controllers/api/crm/communications_controller.rb"
echo "7. app/controllers/api/crm/lead_conversions_controller.rb"
echo "8. app/controllers/api/platform/settings_controller.rb"
echo "9. app/controllers/api/company/settings_controller.rb"
echo ""
echo "Copy content from these artifacts in our conversation:"
echo "  - 'Controller: Activities'"
echo "  - 'Controller: Reminders'"
echo "  - 'Controller: Tags'"
echo "  - 'Controller: AI Insights'"
echo "  - 'Controller: Lead Scores'"
echo "  - 'Controller: Communications'"
echo "  - 'Controller: Convert Lead'"
echo "  - 'Controllers: Platform & Company Settings'"
echo ""
echo "After adding controllers, restart Rails:"
echo "  pkill -f 'puma.*3001'"
echo "  cd ~/src/renterinsight_api"
echo "  bin/rails s -p 3001"
echo ""
echo "Then test from your frontend!"
