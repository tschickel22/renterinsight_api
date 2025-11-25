# frozen_string_literal: true

class CreateFinanceTables < ActiveRecord::Migration[8.0]
  def up
    # Idempotent: Check if tables exist before creating

    # Payment Methods Table
    unless table_exists?(:payment_methods)
      create_table :payment_methods do |t|
        # Tenant isolation
        t.bigint :company_id, null: false
        t.bigint :location_id
        
        # Polymorphic owner (Contact, Lead, or other)
        t.references :owner, polymorphic: true, null: false, index: true
        
        # Payment method type
        t.string :method_type, null: false # 'ach', 'debit_card', 'credit_card', 'cash'
        t.string :nickname # User-friendly name like "Personal Checking"
        
        # ACH fields
        t.string :ach_account_type # 'checking' or 'savings'
        t.string :ach_routing_number_encrypted
        t.string :ach_account_number_encrypted
        t.string :ach_last_4
        
        # Credit/Debit card fields
        t.string :credit_card_number_encrypted
        t.string :credit_card_last_4
        t.string :credit_card_brand # 'Visa', 'MasterCard', 'Amex', 'Discover'
        t.integer :credit_card_exp_month
        t.integer :credit_card_exp_year
        t.string :credit_card_cvv_encrypted
        t.boolean :is_debit_card, default: false
        
        # Billing information
        t.string :billing_first_name
        t.string :billing_last_name
        t.string :billing_street
        t.string :billing_city
        t.string :billing_state
        t.string :billing_zip
        t.string :billing_country, default: 'US'
        
        # External payment gateway references
        t.string :external_id # Gateway payer ID (e.g., Zego GatewayPayerId)
        t.string :alternate_external_id # For alternate uses (e.g., screening fees)
        t.integer :api_partner_id # Which API provider (Zego=2, Stripe=3, etc.)
        
        # Status
        t.boolean :is_default, default: false
        t.boolean :is_active, default: true
        t.boolean :is_verified, default: false
        t.datetime :verified_at
        
        # Soft delete
        t.boolean :is_deleted, default: false
        t.datetime :deleted_at
        
        # Audit
        t.string :created_by
        t.string :updated_by
        t.timestamps
      end

      # Indexes
      add_index :payment_methods, :company_id
      add_index :payment_methods, :location_id
      add_index :payment_methods, [:company_id, :is_deleted]
      add_index :payment_methods, [:owner_type, :owner_id, :is_default]
      add_index :payment_methods, :external_id
      add_index :payment_methods, :method_type
      
      # Foreign keys
      add_foreign_key :payment_methods, :companies, column: :company_id
      add_foreign_key :payment_methods, :locations, column: :location_id
    end

    # Loans Table
    unless table_exists?(:loans)
      create_table :loans do |t|
        # Tenant isolation
        t.bigint :company_id, null: false
        t.bigint :location_id
        
        # Loan identification
        t.string :loan_number, null: false
        t.string :loan_type # 'conventional', 'personal', 'financing', etc.
        t.string :status, null: false, default: 'pending' # 'pending', 'active', 'paid_off', 'defaulted'
        
        # Borrower (polymorphic - Contact, Lead, etc.)
        t.references :borrower, polymorphic: true, null: false, index: true
        
        # Related entity (optional - could be Deal, Vehicle, etc.)
        t.references :financed_entity, polymorphic: true, index: true
        
        # Loan terms
        t.decimal :principal_amount, precision: 12, scale: 2, null: false
        t.decimal :interest_rate, precision: 5, scale: 2 # Annual percentage rate
        t.integer :term_months # Loan duration in months
        t.date :origination_date, null: false
        t.date :maturity_date
        t.date :first_payment_date
        
        # Payment schedule
        t.string :payment_frequency, default: 'monthly' # 'weekly', 'bi_weekly', 'monthly'
        t.decimal :regular_payment_amount, precision: 10, scale: 2
        t.integer :day_of_month_due # For monthly payments (1-31)
        
        # Current state
        t.decimal :current_balance, precision: 12, scale: 2, default: 0.0
        t.decimal :total_paid, precision: 12, scale: 2, default: 0.0
        t.decimal :total_interest_paid, precision: 12, scale: 2, default: 0.0
        t.integer :payments_made, default: 0
        t.integer :payments_remaining
        t.date :last_payment_date
        t.date :next_payment_date
        
        # Late payment tracking
        t.integer :days_past_due, default: 0
        t.decimal :late_fees_assessed, precision: 10, scale: 2, default: 0.0
        
        # Payment method
        t.bigint :default_payment_method_id
        t.boolean :auto_pay_enabled, default: false
        
        # External references
        t.string :external_loan_id # If managed by external system
        
        # Notes and metadata
        t.text :notes
        t.jsonb :metadata, default: {}
        
        # Soft delete
        t.boolean :is_deleted, default: false
        t.datetime :deleted_at
        
        # Audit
        t.string :created_by
        t.string :updated_by
        t.timestamps
      end

      # Indexes
      add_index :loans, :company_id
      add_index :loans, :location_id
      add_index :loans, [:company_id, :loan_number], unique: true
      add_index :loans, [:company_id, :status]
      add_index :loans, [:company_id, :is_deleted]
      add_index :loans, :default_payment_method_id
      add_index :loans, :status
      add_index :loans, :next_payment_date
      
      # Foreign keys
      add_foreign_key :loans, :companies, column: :company_id
      add_foreign_key :loans, :locations, column: :location_id
      add_foreign_key :loans, :payment_methods, column: :default_payment_method_id
    end

    # Payments Table
    unless table_exists?(:payments)
      create_table :payments do |t|
        # Tenant isolation
        t.bigint :company_id, null: false
        t.bigint :location_id
        
        # Payment identification
        t.string :payment_number, null: false
        t.string :payment_type, null: false # 'loan_payment', 'one_time', 'deposit', 'fee'
        t.string :status, null: false, default: 'pending' # 'pending', 'processing', 'completed', 'failed', 'refunded', 'cancelled'
        
        # Payment relationship
        t.bigint :loan_id # If this is a loan payment
        t.bigint :payment_method_id, null: false
        
        # Payer (polymorphic - Contact, Lead, etc.)
        t.references :payer, polymorphic: true, null: false, index: true
        
        # Payment amounts
        t.decimal :amount, precision: 12, scale: 2, null: false
        t.decimal :principal_amount, precision: 12, scale: 2, default: 0.0
        t.decimal :interest_amount, precision: 12, scale: 2, default: 0.0
        t.decimal :fee_amount, precision: 12, scale: 2, default: 0.0
        t.decimal :late_fee_amount, precision: 12, scale: 2, default: 0.0
        
        # Processing fees
        t.decimal :processing_fee, precision: 10, scale: 2, default: 0.0
        t.string :fee_responsibility # 'customer' or 'company'
        t.string :fee_type # 'percentage' or 'fixed'
        t.decimal :fee_value, precision: 10, scale: 2 # The rate % or fixed amount
        t.decimal :total_charged, precision: 12, scale: 2 # amount + processing_fee (if customer pays)
        
        # Payment dates
        t.datetime :scheduled_at
        t.datetime :processed_at
        t.date :payment_date # The effective date for accounting
        
        # External gateway integration
        t.string :external_id # Transaction ID from payment gateway
        t.string :gateway_name # 'zego', 'stripe', 'manual'
        t.text :gateway_response # Store full response for debugging
        t.string :failure_reason
        
        # Refund information
        t.boolean :is_refunded, default: false
        t.decimal :refund_amount, precision: 12, scale: 2
        t.datetime :refunded_at
        t.string :refund_reason
        
        # Notes and metadata
        t.text :notes
        t.jsonb :metadata, default: {}
        
        # Soft delete
        t.boolean :is_deleted, default: false
        t.datetime :deleted_at
        
        # Audit
        t.string :created_by
        t.string :updated_by
        t.timestamps
      end

      # Indexes
      add_index :payments, :company_id
      add_index :payments, :location_id
      add_index :payments, [:company_id, :payment_number], unique: true
      add_index :payments, [:company_id, :status]
      add_index :payments, [:company_id, :is_deleted]
      add_index :payments, :loan_id
      add_index :payments, :payment_method_id
      add_index :payments, :external_id
      add_index :payments, :status
      add_index :payments, :scheduled_at
      add_index :payments, :payment_date
      add_index :payments, [:loan_id, :payment_date]
      
      # Foreign keys
      add_foreign_key :payments, :companies, column: :company_id
      add_foreign_key :payments, :locations, column: :location_id
      add_foreign_key :payments, :loans, column: :loan_id
      add_foreign_key :payments, :payment_methods, column: :payment_method_id
    end

    puts "✅ Finance tables created successfully"
  end

  def down
    drop_table :payments if table_exists?(:payments)
    drop_table :loans if table_exists?(:loans)
    drop_table :payment_methods if table_exists?(:payment_methods)
  end
end
