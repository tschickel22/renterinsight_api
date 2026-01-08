# frozen_string_literal: true
Rails.application.routes.draw do
  # Health check
  get 'up', to: 'rails/health#show', as: :rails_health_check

  # Root
  root to: proc { [200, {}, ['Renter Insight API']] }
  
  # Serve uploaded files (logos, images, etc.) - Legacy URLs without /api prefix
  get 'uploads/*path', to: 'api/uploads#show', format: false
  
  # ==================== WEBHOOKS (NO AUTH REQUIRED) ====================
  namespace :webhooks do
    # Email tracking pixel (no auth required)
    get 'email/:communication_id/pixel.gif', to: 'email_tracking#pixel', as: :email_pixel
    
    # Twilio SMS status callbacks (Twilio signature verification)
    post 'twilio/sms/status', to: 'twilio#sms_status'
    
    # Zego payment webhooks
    post 'zego/processed', to: 'zego#processed'
    post 'zego/canceled', to: 'zego#canceled'
    
    # QuickBooks webhooks
    post 'quickbooks/notifications', to: 'quickbooks#notifications'
  end

  # ==================== PUBLIC INTAKE FORMS ====================
  scope path: 'f', module: 'public', as: 'public' do
    get ':public_id', to: 'forms#show', as: :form
    post ':public_id/submit', to: 'forms#submit', as: :form_submit
  end
  
  # ==================== PUBLIC BROCHURES ====================
  get '/b/:public_id', to: 'api/v1/brochures#public_view', as: :public_brochure
  
  # ==================== PUBLIC SYNDICATION FEEDS ====================
  namespace :public do
    get 'feeds/:id', to: 'syndication_feeds#show', as: :syndication_feed
  end
  
  # ==================== PUBLIC QUOTES ====================
  get '/q/:token', to: 'api/public/quotes#show', as: :public_quote
  post '/q/:token/accept', to: 'api/public/quotes#accept', as: :public_quote_accept
  post '/q/:token/reject', to: 'api/public/quotes#reject', as: :public_quote_reject
  
  # ==================== PUBLIC WARRANTY CLAIMS ====================
  get '/w/:token', to: 'api/public/warranty_claims#show', as: :public_warranty_claim
  post '/w/:token/respond', to: 'api/public/warranty_claims#respond', as: :public_warranty_claim_respond
  
  # ==================== PUBLIC INVOICES ====================
  get '/invoice/:token', to: 'public/invoices#show', as: :public_invoice
  get '/invoice/:token/pdf', to: 'public/invoices#pdf', as: :public_invoice_pdf
  
  # API endpoints for public forms (for frontend)
  namespace :api do
    # ==================== PUBLIC INVITATIONS (No Auth Required) ====================
    namespace :public do
      get 'invitations/verify', to: 'invitations#verify_token'
      post 'invitations/accept', to: 'invitations#accept'
    end
    
    # ==================== PUBLIC INVOICE PAYMENTS (No Auth Required) ====================
    namespace :v1 do
      namespace :public do
        resources :invoice_payments, only: [], param: :token do
          member do
            get '', action: :show
            post :process_payment
          end
        end
      end
    end
    
    scope path: 'f' do
      get ':public_id', to: '/public/forms#show'
      post ':public_id/submit', to: '/public/forms#submit'
    end
    
    # ==================== V1 API ====================
    namespace :v1 do
      # ==================== COMPANY SETTINGS (OPERATIONAL) ====================
      scope path: 'company_settings', controller: 'company_settings' do
        get 'operational', action: :show_operational
        patch 'operational', action: :update_operational
        get 'branding', action: :show_branding
        patch 'branding', action: :update_branding
        get 'communication', action: :show_communication
        patch 'communication', action: :update_communication
        patch 'rbac', action: :update_rbac
        get 'loan', action: :show_loan
        patch 'loan', action: :update_loan
      end
      
      # ==================== NOTES ====================
      resources :notes, only: [:index, :create, :update, :destroy]
      
      # ==================== USER SETTINGS ====================
      scope path: 'user_settings', controller: 'user_settings' do
        get 'profile'
        patch 'profile', action: 'update_profile'
        post 'change_password'
        get 'security'
        patch 'security', action: 'update_security'
        get 'login_activity'
      end
      
      # ==================== NOTIFICATIONS ====================
      resources :notifications, only: [:index, :show, :destroy] do
        collection do
          get :unread_count
          patch :mark_all_read
          post :broadcast
          post :preview_recipients
          get :stats
          post :test  # Test notification endpoint
        end
        member do
          patch :mark_as_read
          patch :mark_as_unread
          get 'attachments/:attachment_id', action: :download_attachment, as: :download_attachment
        end
      end
      
      resources :notification_preferences, path: 'notification-preferences' do
        collection do
          patch :bulk_update
          post :reset_defaults
          patch 'category/:category', action: :update_category
        end
      end
      
      # Notification Settings (Unified Reminder System)
      resource :notification_settings, only: [:show, :update], path: 'notification_settings'
      
      # ==================== TASKS ====================
      resources :tasks do
        member do
          post :complete
          post :reopen
        end
        
        collection do
          get :stats
        end
      end
      
      # ==================== CALENDAR ====================
      scope path: 'calendar', controller: 'calendar' do
        get 'events'
        get 'views', action: :available_views
        get 'stats'
      end
      
      # ==================== SERVICE TICKETS ====================
      resources :service_tickets, path: 'service-tickets' do
        member do
          post :upload_attachments, path: 'upload-attachments'
          post :mark_warranty_suspected, path: 'mark-warranty-suspected'
          post :set_line_billing, path: 'set-line-billing'
          post :generate_customer_invoice, path: 'generate-customer-invoice'
          post :generate_warranty_claim, path: 'generate-warranty-claim'
          post :generate_both, path: 'generate-both'
        end
        
        collection do
          get :stats
        end
      end
      
      # ==================== WARRANTY SYSTEM ====================
      # Manufacturers
      resources :manufacturers, only: [:index, :show]
      
      # Warranty Claims
      resources :warranty_claims, path: 'warranty-claims' do
        member do
          post :submit
          post :approve
          post :deny
          post :request_more_info
          post :resubmit
          post :reopen
          post :close
          post :record_payment
          get :public_link
        end
        collection do
          get :stats
        end
      end
      
      # Manufacturer AR Transactions
      resources :manufacturer_ar_transactions, path: 'manufacturer-ar-transactions' do
        member do
          post :mark_short_paid
          post :write_off
        end
        collection do
          get :stats
        end
      end
      
      # Manufacturer AR Payments
      resources :manufacturer_ar_payments, path: 'manufacturer-ar-payments' do
        member do
          post :upload_attachments
        end
      end
      
      # ==================== VEHICLES/INVENTORY ====================
      resources :vehicles do
        member do
          get :print
          post :clone
          get :tags
          post :tags, to: 'vehicles#add_tags'
          delete 'tags/:tag_name', to: 'vehicles#remove_tag'
        end
        
        collection do
          get :stats
          get :export     # Add export route
          post :bulk_update
          post :bulk_delete
          post :import
        end
        
        # Vehicle image uploads
        resources :images, controller: 'vehicle_images', only: [:create, :destroy]
      end
      
      # ==================== LISTINGS ====================
      resources :listings do
        member do
          post :publish
          post :unpublish
        end
        
        collection do
          get :stats
        end
      end
      
      # ==================== PAYMENT METHODS ====================
      resources :payment_methods, path: 'payment-methods' do
        member do
          patch :set_default
          post :verify
        end
        
        collection do
          get :stats
        end
      end
      
      # Alias for underscore version (some frontend components use payment_methods)
      get 'payment_methods', to: 'payment_methods#index', as: 'payment_methods_underscore_list'
      get 'payment_methods/:id', to: 'payment_methods#show', as: 'payment_methods_underscore_show'
      post 'payment_methods', to: 'payment_methods#create', as: 'payment_methods_underscore_create'
      patch 'payment_methods/:id', to: 'payment_methods#update', as: 'payment_methods_underscore_update'
      delete 'payment_methods/:id', to: 'payment_methods#destroy', as: 'payment_methods_underscore_destroy'
      patch 'payment_methods/:id/set_default', to: 'payment_methods#set_default', as: 'payment_methods_underscore_set_default'
      post 'payment_methods/:id/verify', to: 'payment_methods#verify', as: 'payment_methods_underscore_verify'
      get 'payment_methods/stats', to: 'payment_methods#stats', as: 'payment_methods_underscore_stats'
      
      # ==================== PAYMENTS ====================
      resources :payments do
        member do
          post :cancel
          post :refund
          post :void
        end
        
        collection do
          get :stats
          get :export
        end
      end
      
      # ==================== INVOICES ====================
      resources :invoices do
        member do
          post :send_invoice
          post :send_sms
          post :mark_paid
          post :cancel
        end
        
        collection do
          get :stats
        end
      end
      
      # ==================== LOANS ====================
      resources :loans do
        member do
          post :activate
          post :mark_defaulted, path: 'mark-defaulted'
          post :record_payment, path: 'record-payment'
          post :record_manual_payment, path: 'record-manual-payment'
          get :documents
          post :documents, action: :upload_documents
          delete 'documents/:document_id', action: :destroy_document
          get :amortization_data, path: 'amortization-data'
        end
        
        collection do
          get :stats
          post :calculate_schedule, path: 'calculate-schedule'
          get :search_borrowers, path: 'search-borrowers'
        end
      end
      
      # ==================== BROCHURES ====================
      resources :brochures do
        member do
          post :share
        end
        
        collection do
          get :stats
          get :templates
        end
      end
      
      # ==================== BROCHURE TEMPLATES ====================
      resources :brochure_templates, path: 'brochure-templates', only: [:index, :show, :create, :update, :destroy]
      
      # ==================== RBAC ROLES ====================
      resources :roles do
        member do
          get :permissions
          put :permissions, action: :set_permissions
          post :clone
          post :toggle_visibility
        end
        
        collection do
          get :system, action: :system_roles, as: :system
        end
      end
      
      # ==================== RBAC RESOURCES ====================
      resources :resources, only: [:index, :show, :create, :update, :destroy]
      
      # ==================== RBAC ACTIONS ====================
      resources :actions, only: [:index, :show, :create, :update, :destroy]
      
      # ==================== RBAC SCOPES ====================
      resources :scopes, only: [:index, :show, :create, :update, :destroy]
      
      # ==================== RBAC PERMISSIONS ====================
      scope path: 'permissions', controller: 'permissions' do
        get 'check', action: :check
        get 'user/:user_id', action: :user_permissions
        post 'bulk_check', action: :bulk_check
      end
      
      # ==================== COMPANIES ====================
      resources :companies, only: [] do
        collection do
          get :accessible
        end
      end
      
      # ==================== LOCATIONS ====================
      resources :locations do
        collection do
          get :accessible
        end
        
        member do
          post :restore
          get :users
          get :available_users, path: 'available-users'
          post :assign_user, path: 'assign-user'
          delete 'remove_user/:user_id', action: :remove_user, as: :remove_user
          get :metrics
          get :stats
          get :activities
        end
        
        collection do
          get :stats
          post :bulk_activate
          post :bulk_deactivate
          post :bulk_delete
        end
        
        # ==================== BANK ACCOUNTS (Nested under Locations) ====================
        resources :bank_accounts, path: 'bank-accounts', only: [:index, :create, :update, :destroy] do
          member do
            post :sync_to_zego, path: 'sync-to-zego'
            patch :update_display, path: 'update-display'
          end
        end
        
        # ==================== LOCATION MANUFACTURERS (Warranty System) ====================
        resources :manufacturers, only: [:index, :create, :update, :destroy], controller: 'locations/manufacturers'
      end
      
      # ==================== LAND MANAGEMENT ====================
      resources :land_parcels, path: 'land-parcels' do
        collection do
          get :stats
          get :export
          post :bulk_delete
        end
      end
      
      # ==================== USERS (COMPANY USERS) ====================
      resources :users, only: %i[index show create update destroy] do
        member do
          post :restore
          get :locations, action: :user_locations
          post :assign_location, path: 'assign-location'
          delete 'remove_location/:location_id', action: :remove_location, as: :remove_location
        end
        
        collection do
          get :assignable  # Get users filtered by context (service, sales, finance, etc.)
          post :bulk_activate
          post :bulk_deactivate
        end
      end
      
      # ==================== ACTIVITIES ====================
      
      # ==================== MFA (Multi-Factor Authentication) ====================
      scope path: 'mfa', controller: 'mfa' do
        # Shared MFA routes
        get 'status', action: :status
        post 'disable', action: :disable
        
        # TOTP routes (keep existing)
        post 'enroll', action: :enroll
        post 'verify', action: :verify
        post 'backup_codes/regenerate', action: :regenerate_backup_codes
        
        # SMS routes (new - parallel to TOTP)
        post 'sms/enroll', action: :sms_enroll
        post 'sms/verify', action: :sms_verify
        post 'sms/resend', action: :sms_resend
        post 'sms/disable', action: :sms_disable
      end
      get 'activities/recent', to: 'activities#recent'
      
      # ==================== QUOTES ====================
      resources :quotes do
        member do
          post :send, to: 'quotes#send_quote'
          post :accept
          post :reject
          get :pdf
          get :tags
          post :tags, to: 'quotes#add_tags'
          delete 'tags/:tag_name', to: 'quotes#remove_tag'
        end
        
        collection do
          get :stats
          get :export
        end
      end
      
      # Account activity reminders (for marking as sent)
      post 'account_activities/:id/mark_reminder_sent', to: 'account_activities#mark_reminder_sent'
      
      # Contact activity reminders (for marking as sent)
      post 'contact_activities/:id/mark_reminder_sent', to: 'contact_activities#mark_reminder_sent'
      
      # ==================== COMMISSIONS ====================
      resources :commissions do
        member do
          post :approve
          post :reject
          post :mark_paid, path: 'mark-paid'
          get :audit_trail, path: 'audit-trail'
        end
        
        collection do
          get :stats
          post :calculate
        end
      end
      
      # ==================== COMMISSION PLANS ====================
      resources :commission_plans, path: 'commission-plans' do
        member do
          post :activate
          post :deactivate
          get :components
          get :available_components, path: 'available-components'
          post :add_component, path: 'add-component'
          delete 'remove-component/:component_id', to: 'commission_plans#remove_component'
          patch :reorder_components, path: 'reorder-components'
        end
        
        collection do
          get :stats
        end
      end
      
      # ==================== COMMISSION COMPONENTS ====================
      resources :commission_components, path: 'commission-components' do
        member do
          post :toggle
          post :calculate  # Test calculation with sample deal
        end
        
        collection do
          get :options  # Get dropdown options for form
        end
      end
      
      # ==================== COMMISSION PAYMENTS ====================
      resources :commission_payments, path: 'commission-payments' do
        member do
          post :approve
          post :mark_paid, path: 'mark-paid'
          post :reverse
          post :undo_reversal, path: 'undo-reversal'
          get :statement
        end
        
        collection do
          get :my_commissions, path: 'my-commissions'
          get :stats
          get :dashboard
          get :reports_data, path: 'reports-data'
          post :export
          post :bulk_approve, path: 'bulk-approve'
          post :bulk_mark_paid, path: 'bulk-mark-paid'
          post :bulk_mark_paid_detailed, path: 'bulk-mark-paid-detailed'
          post :generate_for_deal, path: 'generate-for-deal'
          get 'preview-for-deal/:deal_id', action: :preview_for_deal, as: :preview_for_deal
        end
      end
      
      # ==================== COMMISSION RULES ====================
      resources :commission_rules, path: 'commission-rules' do
        member do
          post :calculate
        end
      end
      
      # ==================== PORTAL USERS ====================
      resources :portal_users, path: 'portal_users' do
        collection do
          get :stats
          post :password_reset
          post :invite
        end
      end
      
      # ==================== CONTACTS ====================
      resources :contacts do
        member do
          get :tags, to: 'contacts#tags'  # Get tags for contact
          post :tags, to: 'contacts#add_tags'
          delete 'tags/:tag_name', to: 'contacts#remove_tag'
          patch :opt_in_email, to: 'contacts#opt_in_email'
          patch :opt_out_email, to: 'contacts#opt_out_email'
          patch :opt_in_sms, to: 'contacts#opt_in_sms'
          patch :opt_out_sms, to: 'contacts#opt_out_sms'
          get :deals
          get :quotes
          get :portal_status
          get :documents
          post :documents, action: :upload_documents
        end
        
        collection do
          get :stats
          post :bulk_create
          post :check_duplicate
          post :quick_create
        end
        
        # Contact Communications
        resources :communications, controller: 'contact_communications', only: [:index] do
          collection do
            post :email
            post :sms
            post :log
          end
        end
        
        # Contact Activities
        resources :activities, controller: 'contact_activities' do
          member do
            post :complete
            post :cancel
          end
          collection do
            get :reminders
          end
        end
        
        # Contact Nurture
        get 'nurture', to: 'contact_nurture#index'
        post 'nurture/enroll', to: 'contact_nurture#enroll'
        post 'nurture/:enrollment_id/pause', to: 'contact_nurture#pause'
        post 'nurture/:enrollment_id/resume', to: 'contact_nurture#resume'
        post 'nurture/:enrollment_id/unenroll', to: 'contact_nurture#unenroll'
      end
      
      # ==================== ACCOUNTS ====================
      resources :accounts do
        member do
          post :convert_to_customer
          get :tags, to: 'accounts#tags'  # Get tags for account
          post :tags, to: 'accounts#add_tags'
          delete 'tags/:tag_name', to: 'accounts#remove_tag'
          get :deals
        end
        
        collection do
          get :stats
          get :industries
          get :export
          post :convert_lead
          post :bulk_update
        end
        
        # Nested resources for accounts
        resources :contacts, only: [:index], controller: 'contacts'
        resources :activities, controller: 'account_activities' do
          member do
            post :complete
            post :cancel
          end
          collection do
            get :reminders
          end
        end
        resources :messages, controller: 'account_messages', only: [:index, :create]
        
        # Account Communications
        resources :communications, controller: 'account_communications', only: [:index] do
          collection do
            post :email
            post :sms
            post :log
          end
        end
        
        member do
          get :insights
          get :score
        end
      end
      
      # ==================== QUICKBOOKS INTEGRATION ====================
      namespace :integrations do
        scope path: 'quickbooks' do
          get 'authorize', to: 'quickbooks_oauth#authorize'
          get 'callback', to: 'quickbooks_oauth#callback'
          get 'status', to: 'quickbooks_oauth#status'
          delete 'disconnect', to: 'quickbooks_oauth#disconnect'
          post 'refresh_token', to: 'quickbooks_oauth#refresh_token'
          
          # Sync Routes - Use settings controller for these
          post 'sync/full', to: 'quickbooks_settings#sync_all_entities'
          post 'sync/incremental', to: 'quickbooks_sync#incremental'
          post 'sync/entity', to: 'quickbooks_settings#sync_entity'
          get 'sync/status', to: 'quickbooks_sync#status'
          get 'sync/logs', to: 'quickbooks_sync#logs'
          get 'sync/mappings', to: 'quickbooks_sync#mappings'
          delete 'sync/mappings/:id', to: 'quickbooks_sync#delete_mapping'
          post 'sync/mappings/:id/retry', to: 'quickbooks_sync#retry_mapping'
          
          get 'settings', to: 'quickbooks_settings#show'
          put 'settings', to: 'quickbooks_settings#update'
          delete 'settings', to: 'quickbooks_settings#destroy'
          get 'settings/accounts', to: 'quickbooks_settings#accounts'
          post 'settings/test', to: 'quickbooks_settings#test_connection'
          get 'settings/entity/:entity_type', to: 'quickbooks_settings#entity_settings'
          put 'settings/entity/:entity_type', to: 'quickbooks_settings#update_entity_settings'
          get 'settings/mappings', to: 'quickbooks_settings#field_mappings'
          post 'settings/mappings', to: 'quickbooks_settings#create_field_mapping'
          post 'settings/mappings/defaults', to: 'quickbooks_settings#create_default_mappings'
          put 'settings/mappings/:id', to: 'quickbooks_settings#update_field_mapping'
          delete 'settings/mappings/:id', to: 'quickbooks_settings#delete_field_mapping'
          get 'settings/sync_logs', to: 'quickbooks_settings#sync_logs'
          get 'settings/sync_logs/:id', to: 'quickbooks_settings#sync_log_details'
          
          # Chart of Accounts & Account Mapping
          get 'settings/chart_of_accounts', to: 'quickbooks_settings#chart_of_accounts'
          get 'settings/account_mappings', to: 'quickbooks_settings#account_mappings'
          put 'settings/account_mappings', to: 'quickbooks_settings#update_account_mappings'
          
          # Custom Fields & Custom Field Mapping
          get 'settings/custom_fields', to: 'quickbooks_settings#custom_fields'
          get 'settings/custom_field_mappings', to: 'quickbooks_settings#custom_field_mappings'
          put 'settings/custom_field_mappings', to: 'quickbooks_settings#update_custom_field_mappings'
          
          # QuickBooks Field Schemas (for dropdowns)
          get 'settings/quickbooks_fields', to: 'quickbooks_settings#quickbooks_fields'
          
          # Phase 4 Sync Endpoints - Manual Sync Operations
          post 'sync/entity', to: 'quickbooks_settings#sync_entity'
          post 'sync/all', to: 'quickbooks_settings#sync_all_entities'
        end
      end
      
      namespace :platform do
        resources :quickbooks_settings, only: [] do
          collection do
            get '', action: :show
            put '', action: :update
            get :stats
            get :companies
            get :logs
            post :sync_all
          end
        end
      end
      
      # ==================== ADMIN NAMESPACE (Platform Admin Only) ====================
      namespace :admin do
        resources :manufacturers do
          member do
            post :activate
            post :deactivate
          end
        end
      end
    end
  end

  # One-time setup endpoint for Render free tier
  namespace :api do
    get 'setup', to: 'setup#create'
    post 'setup', to: 'setup#create'
    get 'setup/sources', to: 'setup#create_sources'
    post 'setup/sources', to: 'setup#create_sources'
  end

  # Phase 5A - Unified Login Authentication
  namespace :api do
    namespace :auth do
      post 'login', to: 'login#create'
      post 'logout', to: 'login#destroy'
      post 'refresh', to: 'login#refresh'
      get 'verify', to: 'login#verify'
      get 'me', to: 'login#me'
      
      # Password Reset
      post 'request_password_reset', to: 'password_reset#request_reset'
      post 'verify_reset_token', to: 'password_reset#verify_token'
      post 'reset_password', to: 'password_reset#reset_password'
      
      # Magic Link
      post 'request_magic_link', to: 'magic_link#request_magic_link'
      get 'verify_magic_link', to: 'magic_link#verify_magic_link'
      
      # MFA (Multi-Factor Authentication) - Login Flow
      scope path: 'mfa', controller: 'mfa' do
        post 'request_code'
        post 'verify_code'
        get 'settings'
        patch 'toggle'
      end
      
      # Impersonation (Platform Admin Only)
      post 'impersonate', to: 'impersonation#create'
      post 'stop_impersonation', to: 'impersonation#destroy'
      delete 'impersonation', to: 'impersonation#destroy'
      
      # Phase 6 - Token Management
      resource :tokens, only: [] do
        post :refresh, on: :collection
        post :validate, on: :collection
        delete :logout, on: :collection
      end
    end
    
    # MFA (Multi-Factor Authentication) - Phase 3: User Enrollment
    scope path: 'mfa' do
      # Status
      get 'status', to: 'mfa#status'
      
      # Enrollment
      post 'enroll/start', to: 'mfa#enroll_start'
      post 'enroll/verify', to: 'mfa#enroll_verify'
      
      # Backup Codes
      get 'backup-codes', to: 'mfa#backup_codes_status'
      post 'backup-codes/regenerate', to: 'mfa#regenerate_backup_codes'
      
      # Disable
      post 'disable', to: 'mfa#disable'
      
      # Login Verification (Phase 4)
      post 'verify-login', to: 'mfa#verify_login'
    end
    
    # Phase 6 - Unified Invitation System (User Invitations)
    # NOTE: Public invitation endpoints are declared at the top of the api namespace
    
    # Authenticated invitation endpoints
    resources :invitations, only: [:show, :destroy] do
      member do
        post :resend
      end
    end
    
    # Company-scoped invitations
    scope path: 'companies/:company_id' do
      get 'invitations', to: 'invitations#index'
      post 'invitations', to: 'invitations#create'
    end
  end

  # Mount ActionCable for WebSocket notifications
  mount ActionCable.server => '/cable'

  namespace :api, defaults: { format: :json } do
    # ==================== INVITATIONS (User Invitations) ====================
    # NOTE: Public invitation endpoints are declared at the top of the first api namespace (line ~26)
    
    # ==================== COMPANIES API ====================
    resources :companies, only: [] do
      resources :users, controller: 'companies/users' do
        collection do
          get :available_roles, path: 'available-roles'
        end
        
        member do
          post :resend_invitation
        end
      end
      
      # Alias invitations to users controller for frontend compatibility
      resources :invitations, controller: 'companies/users', only: [:index, :create] do
        member do
          post :resend, action: :resend_invitation
          delete '', action: :destroy
        end
      end
    end
    
    # ==================== SETTINGS API ====================
    get 'settings/tenant_basic', to: 'settings#tenant_basic'  # Basic tenant info for all authenticated users
    get 'settings/tenant', to: 'settings#tenant'  # Full tenant settings (requires company_settings permission)
    get 'settings/platform', to: 'settings#platform'  # Get platform defaults
    patch 'settings', to: 'settings#update'
    put 'settings', to: 'settings#update'  # Support PUT for company settings
    delete 'settings', to: 'settings#destroy'  # Reset to platform defaults
    patch 'settings/branding', to: 'settings#update_branding'
    get 'settings/quotes', to: 'settings#quotes'
    patch 'settings/quotes', to: 'settings#update_quotes'
    
    # Custom Fields
    get 'settings/custom_fields', to: 'settings#custom_fields'
    post 'settings/custom_fields', to: 'settings#create_custom_field'
    patch 'settings/custom_fields/:id', to: 'settings#update_custom_field'
    delete 'settings/custom_fields/:id', to: 'settings#destroy_custom_field'
    
    # ==================== UPLOADS API ====================
    get 'uploads/*path', to: 'uploads#show', format: false  # Serve uploaded files
    post 'uploads/logo', to: 'uploads#logo'
    post 'uploads', to: 'uploads#create'
    delete 'uploads', to: 'uploads#destroy'

    # ==================== CRM NAMESPACE ====================
    namespace :crm do
      # ==================== SOURCES ====================
      resources :sources, only: %i[index create update destroy] do
        member { get :stats }
        collection { get :stats }
      end

      # ==================== TAGS ====================
      resources :tags, only: %i[index create update destroy] do
        member do
          get :analytics
        end
        collection do
          post :assign
          get 'entity/:entity_type/:entity_id', to: 'tags#entity_tags'
        end
      end
      delete 'tags/assignments/:id', to: 'tags#remove_assignment'

      # ==================== AI INSIGHTS (Non-Lead-Scoped) ====================
      resources :ai_insights, only: [] do
        member { post :mark_read }
      end

      # ==================== REMINDERS (Non-Lead-Scoped) ====================
      resources :reminders, only: [] do
        member do
          post :complete
          patch :complete
        end
      end

      # ==================== LEAD SCORES ====================
      resources :lead_scores, only: [] do
        collection do
          get ':lead_id', to: 'lead_scores#show'
          post ':lead_id/calculate', to: 'lead_scores#calculate'
        end
      end

      # ==================== COMMUNICATIONS (Non-Lead-Scoped) ====================
      # These routes accept lead_id in the request body
      post 'communications/email', to: 'communications#email'
      post 'communications/sms', to: 'communications#sms'

      # ==================== ACTIVITIES (Collection Endpoints) ====================
      # Collection endpoints for aggregating activities across all entities
      get 'leads/activities', to: 'activities#lead_activities'
      get 'accounts/activities', to: 'activities#account_activities'
      get 'contacts/activities', to: 'activities#contact_activities'
      get 'deals/activities', to: 'activities#deal_activities'

      # ==================== LEADS ====================
      resources :leads, only: %i[index show create update destroy] do
        # Member routes (actions on specific lead)
        member do
          # Notes
          post :notes
          
          # Conversion
          post :convert
          
          # Scoring
          get :score, to: 'lead_scores#show'
          post 'score/calculate', to: 'lead_scores#calculate'
        end

        # Nested resources
        
        # Activities
        resources :activities, only: %i[index create update destroy]

        # Communications
        resources :communications, only: %i[index create] do
          collection do
            post :send_email
            post :send_sms
          end
        end
        # Alternative communication routes
        post 'communications/email', to: 'communications#send_email'
        post 'communications/sms', to: 'communications#send_sms'

        # AI Insights
        resources :ai_insights, only: %i[index] do
          collection { post :generate }
        end
        # Alternative hyphenated routes for AI Insights
        get 'ai-insights', to: 'ai_insights#index'
        post 'ai-insights/generate', to: 'ai_insights#generate'

        # Reminders
        resources :reminders, only: %i[index create update destroy] do
          member do
            post :complete
            patch :complete
          end
        end

        # Tasks
        resources :tasks, only: %i[create update destroy], controller: 'lead_tasks'
        
        # Lead Activities (unified activities)
        resources :lead_activities, only: %i[index show create update destroy] do
          member do
            post :complete
            post :cancel
          end
          collection do
            get :reminders
          end
        end

        # Lead reminders endpoint (for activity notifications)
        get 'reminders/upcoming', to: 'lead_activities#reminders'
        post 'lead_activities/:id/mark_reminder_sent', to: 'lead_activities#mark_reminder_sent'

        # Tags (lead-scoped)
        get 'tags', to: 'tags#entity_tags_for_lead'
        post 'tags', to: 'tags#assign_to_lead'
        delete 'tags/:tag_id', to: 'tags#remove_from_lead'
      end

      # ==================== NURTURE ====================
      namespace :nurture do
        resources :sequences, only: %i[index create update destroy] do
          collection { post :bulk }
          resources :steps, only: %i[index create update destroy]
        end

        resources :enrollments, only: %i[index create update destroy] do
          collection { post :bulk }
        end

        resources :templates, only: %i[index create update destroy] do
          collection { post :bulk }
          member { delete 'attachments/:attachment_id', to: 'templates#delete_attachment' }
        end
      end

      # ==================== INTAKE ====================
      namespace :intake do
        resources :forms do
          collection { post :bulk }
        end

        resources :submissions, only: %i[index create] do
          collection { post :bulk }
        end
      end

      # ==================== DEALS (SALES PIPELINE) ====================
      resources :deals, only: %i[index show create update destroy] do
        collection do
          get :metrics
          get :forecast
          get :by_stage
        end
        
        member do
          post :move_stage
          get :tags
          post :tags, to: 'deals#add_tags'
          delete 'tags/:tag_name', to: 'deals#remove_tag'
          get :commission_breakdown # Commission economics breakdown
          get :financials # NEW: Get deal financials (permission-gated)
          patch :financials, to: 'deals#update_financials' # NEW: Update deal financials (permission-gated)
        end
        
        # Commission Payments (nested under deals)
        resources :commission_payments, only: [:index], controller: 'commission_payments', path: 'commissions' do
          collection do
            post :preview
          end
        end
        
        # Deal Activities (unified activities)
        resources :deal_activities, only: %i[index show create update destroy] do
          member do
            post :complete
            post :cancel
          end
          collection do
            get :reminders
          end
        end
        
        # Deal reminders endpoint (for activity notifications)
        post 'deal_activities/:id/mark_reminder_sent', to: 'deal_activities#mark_reminder_sent'
        
        # Nested resources for deals
        resources :products, only: %i[index show create update destroy], controller: 'deal_products' do
          collection do
            post :bulk_create
          end
        end
        
        resources :stage_histories, only: %i[index show create], controller: 'deal_stage_histories'
        
        resources :approvals, only: %i[index show create update destroy] do
          member do
            post :approve
            post :reject
            post :cancel
          end
        end
        
        # Win/Loss Report (singular resource - one per deal)
        resource :win_loss_report, only: %i[show create update destroy], controller: 'win_loss_reports'
      end
      
      # Win/Loss Reports collection routes (not deal-scoped)
      resources :win_loss_reports, only: %i[index] do
        collection do
          get :summary
          get :trends
        end
      end
      
      # ==================== COMMISSIONS ====================
      # Commission Plans
      resources :commission_plans, path: 'commission-plans', only: %i[index show create update destroy] do
        collection do
          get :stats
        end
        
        member do
          post :activate
          post :deactivate
          get :components
          get :available_components, path: 'available-components'
          post :add_component, path: 'add-component'
          delete 'remove-component/:component_id', to: 'commission_plans#remove_component'
          patch :reorder_components, path: 'reorder-components'
        end
      end
      
      # Commission Components
      resources :commission_components, path: 'commission-components', only: %i[index show create update destroy] do
        collection do
          get :stats
        end
        
        member do
          post :activate
          post :deactivate
        end
      end
      
      # Commission Payments (top-level routes)
      resources :commission_payments, path: 'commission-payments', only: %i[index show create update destroy] do
        collection do
          get :stats
          post :bulk_approve
          post :bulk_pay
        end
        
        member do
          post :approve
          post :pay
          post :reverse
        end
      end
      
      # ==================== APPROVALS (Non-Deal-Scoped) ====================
      # Root-level approval routes for listing all approvals
      resources :approvals, only: %i[index show] do
        member do
          post :approve
          post :reject
          post :escalate
        end
      end
      
      # ==================== TERRITORIES ====================
      resources :territories, only: %i[index show create update destroy] do
        member do
          get :stats
          post :assign_user
        end
      end
      
      # ==================== CONTACTS ====================
      resources :contacts, only: %i[index show create update destroy] do
        # Contact Activities (unified activities)
        resources :activities, controller: 'contact_activities', only: %i[index show create update destroy] do
          member do
            post :complete
            post :cancel
          end
          collection do
            get :reminders
          end
        end
        
        # Contact reminders endpoint (for activity notifications)
        post 'activities/:id/mark_reminder_sent', to: 'contact_activities#mark_reminder_sent'
      end
    end

    # ==================== COMPANY SETTINGS ====================
    namespace :company do
      resource :settings, only: %i[show update] do
        post :test_email, on: :collection
        post :test_sms, on: :collection
      end
      
      # Company Manufacturers (Warranty System)
      resources :manufacturers, only: [:index, :create, :update, :destroy]
      
      # Company Security Settings
      scope path: ':company_id/security' do
        get 'settings', to: 'security_settings#show'
        patch 'settings', to: 'security_settings#update'
        get 'mfa_stats', to: 'security_settings#mfa_stats'
      end
    end

    # ==================== PLATFORM SETTINGS ====================
    namespace :platform do
      # ==================== SUBSCRIPTION PLANS ====================
      resources :subscription_plans, path: 'subscription-plans' do
        member do
          post :set_modules
        end
        collection do
          get :modules
          get :templates
        end
      end
      
      # ==================== TENANTS (TENANT MANAGEMENT) ====================
      resources :tenants do
        # Tenant Subscription Management
        resource :subscription, only: [:show, :create, :update], controller: 'tenant_subscriptions' do
          post :cancel
          post :suspend
          post :activate
        end
        
        # Tenant Module Overrides
        get :modules, to: 'tenant_subscriptions#modules'
        post 'modules/override', to: 'tenant_subscriptions#override_module'
        delete 'modules/override/:module_key', to: 'tenant_subscriptions#remove_override'
        post 'modules/bulk_override', to: 'tenant_subscriptions#bulk_override'
        
        member do
          get :check_domain_dns
          post :verify_domain
          post :generate_domain_token
          get :check_email_dns
          post :generate_email_dns_records
          post :verify_email_domain
        end
        collection do
          get :check_subdomain_available
          get :check_domain_available
        end
      end
      
      resource :settings, only: %i[show update] do
        post :test_email, on: :collection
        post :test_sms, on: :collection
      end
      
      # ==================== PLATFORM COMMUNICATIONS ====================
      # Unified communications API for all entity types
      get 'communications/:entity_type/:entity_id/history', to: 'communications#history'
      get 'communications/:entity_type/:entity_id/stats', to: 'communications#stats'
      delete 'communications/:entity_type/:entity_id/messages/:id', to: 'communications#destroy'
      post 'communications/email', to: 'communications#email'
      post 'communications/sms', to: 'communications#sms'
      
      # Communication templates - Namespaced RESTful routes
      namespace :communications do
        resources :templates, only: [:index, :show, :create, :update, :destroy] do
          member do
            post :test
          end
        end
      end
      
      # ==================== SYNDICATION PARTNERS ====================
      resources :syndication_partners, path: 'syndication-partners' do
        member do
          patch :toggle
          post :regenerate_token, path: 'regenerate-token'
        end
      end
    end
  end

  # Phase 4A & 4B - Portal (Portal User System)
  namespace :api do
    namespace :portal do
      # Phase 4A - Authentication (Portal Users)
      post 'auth/login', to: 'auth#login'
      post 'auth/request_magic_link', to: 'auth#request_magic_link'
      post 'auth/magic-link', to: 'auth#request_magic_link'
      get 'auth/verify_magic_link', to: 'auth#verify_magic_link'
      post 'auth/request_reset', to: 'auth#request_reset'
      post 'auth/forgot-password', to: 'auth#forgot_password'
      post 'auth/reset-password', to: 'auth#reset_password'
      patch 'auth/reset_password', to: 'auth#reset_password'
      get 'auth/profile', to: 'auth#profile'
      get 'auth/verify_invitation', to: 'auth#verify_invitation'
      post 'auth/complete_registration', to: 'auth#complete_registration'
      
      # Phase 4B - Quote Management
      resources :quotes, only: [:index, :show] do
        member do
          patch :accept
          patch :reject
        end
      end
      
      # Phase 4C - Communications
      resources :communications, only: [:index, :show, :create] do
        member do
          patch :mark_as_read
        end
      end
      get 'communications/threads', to: 'communications#threads'
      post 'communications/:thread_id/reply', to: 'communications#create'
      
      # Phase 4E - Document Management
      resources :documents, only: [:index, :show, :create, :destroy] do
        member do
          get :download
        end
      end

      # Phase 4D - Communication Preferences
      get 'preferences', to: 'preferences#show'
      patch 'preferences', to: 'preferences#update'
      get 'preferences/history', to: 'preferences#history'
      
      # Portal Settings (Branding)
      get 'settings/branding', to: 'settings#branding'
      
      # Phase 4F - Loans with Payment Processing
      resources :loans, only: [:index, :show] do
        member do
          get :payments
          post :make_payment
        end
      end
      
      # Phase 4F - Payment Methods (Saved Payment Methods)
      resources :payment_methods, only: [:index, :destroy], path: 'payment-methods' do
        member do
          post :set_default
        end
      end
      
      # Phase 4G - Invoices with Payment Processing
      resources :invoices, only: [:index, :show] do
        member do
          get :payments
          post :make_payment
          get :download
        end
        
        collection do
          get :stats
        end
      end
      
      # Portal Service Tickets
      resources :service_tickets, only: [:index, :show, :create], path: 'service-tickets'
    end
  end

end
