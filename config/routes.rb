# frozen_string_literal: true
Rails.application.routes.draw do
  # Health check
  get 'up', to: 'rails/health#show', as: :rails_health_check

  # Root
  root to: proc { [200, {}, ['Renter Insight API']] }
  
  # Serve uploaded files (logos, images, etc.) - Legacy URLs without /api prefix
  get 'uploads/*path', to: 'api/uploads#show', format: false
  
  # Public tokenized SMS reply links — no authentication required
  get  'r/:token',       to: 'sms_replies#show'
  post 'r/:token/reply', to: 'sms_replies#reply'

  # ==================== PUBLIC AGREEMENT SIGNING (No Auth Required) ====================
  get  'sign/:token',          to: 'public/agreement_signing#show'
  post 'sign/:token/view',    to: 'public/agreement_signing#view_agreement'
  post 'sign/:token/sign',    to: 'public/agreement_signing#sign'
  post 'sign/:token/decline', to: 'public/agreement_signing#decline'
  get  'sign/:token/download', to: 'public/agreement_signing#download'

  # ==================== WEBHOOKS (NO AUTH REQUIRED) ====================
  namespace :webhooks do
    # Email tracking pixel (no auth required)
    get 'email/:communication_id/pixel.gif', to: 'email_tracking#pixel', as: :email_pixel
  end
  
  # Inbound email webhook (separate namespace - singular)
  namespace :webhook do
    # Inbound email handling (BCC capture + reply tracking)
    post 'inbound_mail/handle', to: 'inbound_mail#handle'
  end
  
  # Legacy route aliases (for existing SNS subscription)
  post 'webhooks/inbound_mail/process', to: 'webhook/inbound_mail#handle'
  post 'webhooks/inbound_mail/handle', to: 'webhook/inbound_mail#handle'
  
  # Other webhooks (plural namespace)
  namespace :webhooks do
    # Twilio SMS status callbacks (Twilio signature verification)
    post 'twilio/sms/status', to: 'twilio#sms_status'
    post 'twilio/sms/inbound', to: 'twilio#sms_inbound'
    
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
  
  # ==================== PUBLIC LISTING VIEW ====================
  get '/l/:id', to: 'api/v1/listings#public_view', as: :public_listing
  
  # ==================== PUBLIC BLOG (No Auth Required) ====================
  get 'api/public/websites/:token/blog', to: 'api/public/blog_posts#index'
  get 'api/public/websites/:token/blog/categories', to: 'api/public/blog_posts#categories'
  get 'api/public/websites/:token/blog/:slug', to: 'api/public/blog_posts#show'
  
  # ==================== PUBLIC SYNDICATION FEEDS ====================
  namespace :public do
    get 'feeds/:id', to: 'syndication_feeds#show', as: :syndication_feed
    
    # ==================== PUBLIC INVENTORY (Vehicle Catalog) ====================
    resources :inventory, only: [:index, :show], controller: 'inventory' do
      collection do
        get :filters  # Get available filter options
      end
    end

    # ==================== PUBLIC LAND PARCELS ====================
    resources :land_parcels, only: [:index, :show], controller: 'land_parcels' do
      collection do
        get :filters
      end
    end
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

      # ==================== PUBLIC CONFIGURATION VIEWING ====================
      get 'configurations/:token', to: 'configurations#show', as: :public_configuration

      # ==================== PUBLIC CONFIGURATOR (Anonymous Builder) ====================
      scope 'configurator/:subdomain' do
        get 'info', to: 'configurator#company_info'
        get 'floor-plans', to: 'configurator#floor_plans'
        get 'floor-plans/:id', to: 'configurator#floor_plan_detail'
        post 'submit', to: 'configurator#submit'
      end
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

    # ==================== PUBLIC PROJECT PROGRESS (No Auth Required) ====================
    namespace :v1 do
      namespace :public do
        get 'project-progress/:token', to: 'project_progress#show', as: :public_project_progress
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
        get 'portal_modules', action: :show_portal_modules
        patch 'portal_modules', action: :update_portal_modules
        patch :save_communication_settings
        delete :clear_communication_settings
        get 'form_states', action: :show_form_states
        patch 'form_states', action: :update_form_states
        get 'tax_rate_for_state', action: :tax_rate_for_state
      end
      
      # ==================== GLOBAL SEARCH ====================
      get 'search/global', to: 'search#global'
      
      # ==================== COMPANIES (Platform Admin) ====================
      scope path: 'companies', controller: 'companies' do
        get 'accessible', action: :accessible
        get ':id/locations', action: :locations
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
        get 'notifications'
        patch 'notifications', action: 'update_notifications'
      end
      
      # ==================== USER EMAIL CONNECTIONS ====================
      resources :user_email_connections, path: 'user-email-connections' do
        member do
          post :test
          post :set_default
          post :send_verification
        end
        collection do
          get :check_domain
          post :verify  # Token-based verification (no auth on token itself)
        end
      end
      
      # ==================== SETTINGS (Public Inventory) ====================
      namespace :settings do
        patch :company
        post :regenerate_public_inventory_token
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

      # ==================== PROJECTS ====================
      resources :projects do
        collection do
          get :summary
          get :grid
        end
        member do
          post :advance_phase
          post :undo_advance
          post :set_phase_status
          post :skip_phase
          post :toggle_task   # POST body: { phase_id:, task_id: }
          post :assign_phase_task_contractor     # POST body: { phase_id:, task_id:, contractor_id: }
          delete :unassign_phase_task_contractor  # DELETE body: { phase_id:, task_id:, contractor_id: }
          post :assign_phase_task_user            # POST body: { phase_id:, task_id:, user_id: }
          delete :unassign_phase_task_user        # DELETE body: { phase_id:, task_id: }
        end
        # Nested phase tasks (CRUD only — toggle uses project member action above)
        resources :phases, only: [:update], controller: 'project_phases' do
          resources :tasks, controller: 'project_phase_tasks', only: [:index, :create, :update, :destroy]
          # Phase 2A: Rich project tasks (with checklists, dependencies, etc.)
          resources :project_tasks, controller: 'project_tasks', only: [:index, :create] do
            collection do
              post :reorder
            end
          end
        end

        # Phase 2A: Project tasks (show/update/destroy at project level)
        resources :project_tasks, controller: 'project_tasks', only: [:show, :update, :destroy], as: :project_task_detail do
          member do
            patch :update_status
            post :assign_contractor
            delete :unassign_contractor
          end

          resources :checklists, controller: 'project_task_checklists', only: [:create, :update, :destroy] do
            member do
              post :add_item
            end
          end

          resources :checklist_items, controller: 'project_task_checklists', only: [] do
            member do
              patch :toggle_item
              delete :delete_item
            end
          end
        end

        # Phase 2A: Notification preferences
        resources :notification_preferences, controller: 'project_notification_preferences', only: [:index, :create, :update, :destroy] do
          collection do
            post :auto_setup
          end
        end

        # Phase 2D: Cost tracking, materials, documents
        resources :cost_items, controller: 'project_cost_items' do
          collection do
            get :summary
          end
        end

        resources :materials, controller: 'project_material_usages' do
          member do
            post :check_out
            post :mark_used
            post :return_parts
          end
          collection do
            get :search_parts
          end
        end

        resources :documents, controller: 'project_documents'
      end

      # Phase 2A: Offline sync
      post 'offline_sync', to: 'offline_sync#create'

      resources :project_templates, path: 'project-templates' do
        member do
          post :duplicate
        end
      end

      # ==================== CALENDAR ====================
      scope path: 'calendar', controller: 'calendar' do
        get 'events'
        get 'views', action: :available_views
        get 'stats'
      end
      
      # ==================== DASHBOARD ====================
      scope path: 'dashboard', controller: 'dashboard' do
        get 'presets', action: :presets
        get 'layout/:preset_id', action: :layout
        post 'layout/:preset_id', action: :save_layout
        delete 'layout/:preset_id', action: :reset_layout
        get 'metrics/:card_type', action: :metrics
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
          post :assign_contractor, path: 'assign-contractor'
          delete :unassign_contractor, path: 'unassign-contractor'
        end
        
        collection do
          get :stats
        end
      end
      
      # ==================== CONTRACTORS ====================
      resources :contractors do
        collection do
          get :stats
          get :vendors
        end

        resources :contractor_assignments, only: [:index, :create, :update, :destroy]
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
      
      # ==================== WEBSITE BUILDER ====================
      resources :websites do
        member do
          post :publish
          post :unpublish
          post :sync_branding  # Sync branding from Company/Location settings
        end
        
        collection do
          get :stats
          get :branding_preview  # Preview branding before sync
          get 'by_token/:token', action: :by_token  # ⭐ PUBLIC - Preview website by token
          get 'by_slug_public/:slug', action: :by_slug_public  # ⭐ PUBLIC - Preview website by slug (Safari compatible)
          get 'by_slug/:slug', action: :by_slug  # Authenticated preview by slug
        end
        
        # Website Pages (nested under websites)
        resources :pages, controller: 'website_pages' do
          member do
            post :show_page, path: 'show'
            post :hide_page, path: 'hide'
            post :reorder
          end
          
          collection do
            post :bulk_reorder
          end
        end
        
        # Website Media (nested under websites)
        resources :media, controller: 'website_media'
        
        # Blog Posts (nested under websites)
        resources :blog_posts, path: 'blog/posts', controller: 'blog_posts' do
          member do
            post :publish
            post :unpublish
            post :schedule
            post :increment_views
          end
        end
        
        # Blog Categories (nested under websites)
        resources :blog_categories, path: 'blog/categories', controller: 'blog_categories' do
          collection do
            post :bulk_reorder
          end
        end
      end
      
      # Global media endpoints (not nested under websites)
      resources :media, controller: 'website_media', only: [:show, :update, :destroy] do
        collection do
          get :stats
        end
      end
      
      # ==================== VEHICLES/INVENTORY ====================
      resources :vehicles do
        member do
          get :print
          post :clone
          post :share
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
        
        # Vehicle packages (Package Builder)
        resources :packages, controller: 'inventory_packages' do
          collection do
            post :reorder
            post :apply_template
          end
        end
      end
      
      # ==================== PACKAGE TEMPLATES ====================
      resources :package_templates do
        collection do
          post :reorder
        end
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
          post :finalize
          get :pdf
          get :draw_schedule_pdf
          post :mark_inventory_used, path: 'mark-inventory-used'  # Manual inventory override
        end
        
        collection do
          get :stats
          post :convert_from_quote, path: 'convert-from-quote'  # Quote → Invoice conversion
        end
      end

      resources :draw_schedule_templates do
        member do
          post :set_default
          get :preview
        end
      end

      resources :invoice_terms_templates do
        member do
          post :set_default
        end
      end

      resources :invoice_notes_templates do
        member do
          post :set_default
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
          post :bulk_share
        end
      end
      
      # ==================== BROCHURE TEMPLATES ====================
      resources :brochure_templates, path: 'brochure-templates', only: [:index, :show, :create, :update, :destroy]
      
      # ==================== COMPANY DOMAINS (CUSTOM DOMAINS) ====================
      resources :company_domains, path: 'company-domains' do
        member do
          post :verify
          post :check_dns, path: 'check-dns'
          post :activate
          post :deactivate
        end
      end
      
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
          patch :save_communication_settings
          delete :clear_communication_settings
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
          post :reset_mfa
          get :mfa_status
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
          post :mark_parts_used, path: 'mark-parts-used'
        end
        
        collection do
          get :stats
          get :export
          get :search_parts, path: 'search-parts'
        end
        
        # Quote Inventory Usages (Parts tracking)
        resources :quote_inventory_usages, only: [:index, :create, :destroy], path: 'inventory-usages' do
          member do
            post :mark_used, path: 'mark-used'
          end
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
        member do
          post :generate_proxy_token
        end
        collection do
          get :stats
          post :password_reset
          post :invite
        end
      end
      
      # ==================== PARTS & INVENTORY MODULE ====================
      # Manufacturers
      resources :manufacturers do
        member do
          get :parts
        end
        collection do
          get :stats
          get :autocomplete
        end
      end
      
      # Part Categories
      resources :part_categories, path: 'part-categories' do
        collection do
          get :tree
        end
      end
      
      # Parts
      resources :parts do
        member do
          get :stock_by_location, path: 'stock-by-location'
          get :transaction_history, path: 'transaction-history'
          post :upload_image, path: 'upload-image'
          delete 'delete-image/:image_index', action: :delete_image, as: :delete_image
        end
        collection do
          get :stats
          get :export  # Export parts to CSV
          get :autocomplete  # Autocomplete suggestions
          get :find_by_identifier  # Get full part details by SKU/Barcode
          get :manufacturer_names  # List all manufacturer names with counts
          post :rename_manufacturer  # Rename manufacturer across all parts
          delete :delete_manufacturer  # Delete if unused
          post :rename_part_name  # Rename part name across all parts
          delete :delete_part_name  # Delete if unused
        end
      end
      
      # Suppliers
      resources :suppliers do
        member do
          get :parts
        end
        collection do
          get :stats
        end
      end
      
      # Purchase Orders
      resources :purchase_orders, path: 'purchase-orders' do
        member do
          post :send_to_supplier, path: 'send'
          post :cancel
          get :receiving_history, path: 'receiving-history'
        end
        collection do
          get :stats
        end
      end
      
      # Bins
      resources :bins do
        collection do
          get :stats
          post :transfer
        end
      end
      
      # Inventory Transactions
      resources :inventory_transactions, path: 'inventory-transactions', only: [:index, :show] do
        collection do
          post :receive
          post :transfer
          post :adjust
          post :consume
          post :return, action: :return_inventory
        end
      end
      
      # Stock Balances
      resources :stock_balances, path: 'stock-balances', only: [:index] do
        collection do
          get :summary
          get 'by_part/:part_id', action: :by_part, as: :by_part
          get 'by_location/:location_id', action: :by_location, as: :by_location
        end
        member do
          post :reserve
          post :release
        end
      end
      
      # Reorder Rules
      resources :reorder_rules, path: 'reorder-rules' do
        collection do
          get :needs_reorder, path: 'needs-reorder'
        end
      end
      
      # ==================== HOME CONFIGURATOR ====================
      resources :floor_plans, path: 'floor-plans', only: [:index, :show]
      resources :company_floor_plans, path: 'company-floor-plans', only: [:index, :show, :create, :update, :destroy]
      resources :configurations do
        member do
          post :calculate_price, path: 'calculate-price'
          post :share
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
          get :contacts  # Account contacts list
          get 'communications/rollup', to: 'accounts#communications_rollup'  # Communication rollup across all contacts
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
      
      # ==================== OAUTH EMAIL CONNECTIONS ====================
      scope path: 'oauth-email', controller: 'oauth_email' do
        get  'authorize',   action: :authorize
        get  'callback',    action: :callback
        delete 'disconnect', action: :disconnect
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

      # ==================== PARTNER API KEY MANAGEMENT ====================
      resources :api_keys, only: [:index, :show, :create, :update, :destroy], path: 'api-keys' do
        collection do
          get :available_resources
        end
        member do
          post :revoke
        end
      end

      # ==================== WEBHOOK MANAGEMENT ====================
      resources :webhook_endpoints, only: [:index, :show, :create, :update, :destroy], path: 'webhook-endpoints' do
        collection do
          get :available_events
        end
        member do
          post :test
        end
        resources :deliveries, only: [:index, :show], controller: 'webhook_deliveries'
      end

      # ==================== CUSTOM FIELDS ====================
      resources :custom_fields, only: [:index, :create, :update, :destroy] do
        member do
          get :migrations
          post :migrations, action: :create_migrations
        end
        collection do
          get :migration_recommendations
        end
      end

      # ==================== CUSTOM FIELD FILE/IMAGE UPLOADS ====================
      resources :custom_field_uploads, only: [:create] do
        collection do
          delete :destroy, action: :destroy
        end
      end

      # ==================== ENTITY BUYERS (Co-Buyers, Guarantors, Cosigners) ====================
      resources :deals, only: [] do
        resources :buyers, controller: 'entity_buyers', only: [:index, :create, :update, :destroy]
      end
      resources :quotes, only: [] do
        resources :buyers, controller: 'entity_buyers', only: [:index, :create, :update, :destroy]
      end
      resources :invoices, only: [] do
        resources :buyers, controller: 'entity_buyers', only: [:index, :create, :update, :destroy]
      end

      # ==================== PAGE LAYOUTS ====================
      get 'page_layouts/:module_name', to: 'page_layouts#show'
      patch 'page_layouts/:module_name', to: 'page_layouts#update'
      post 'page_layouts/:module_name/reset', to: 'page_layouts#reset'
      get 'page_layouts/:module_name/field_definitions', to: 'page_layouts#field_definitions'

      # Field option overrides (company-specific dropdown customization)
      get 'page_layouts/:module_name/field_option_overrides', to: 'page_layouts#field_option_overrides'
      put 'page_layouts/:module_name/field_option_overrides/:field_key', to: 'page_layouts#update_field_option_override'
      delete 'page_layouts/:module_name/field_option_overrides/:field_key', to: 'page_layouts#delete_field_option_override'

      # ==================== AGREEMENTS & E-SIGN ====================
      resources :agreement_categories, only: [:index, :create, :update, :destroy]

      resources :agreement_templates do
        collection do
          get :ai_scan_usage, action: :ai_scan_usage_info
          post :multi_state_create
          patch :multi_state_update
          delete :delete_group
          get :state_groups
        end
        member do
          post :duplicate
          post :preview
          post :vision_scan
          get :cached_scan
          patch :save_scan_mappings
          delete :clear_scan_cache
          post :upload_example_document
          delete :remove_example_document
          post :smart_scan
          get 'custom_fields', to: 'agreement_templates#list_custom_fields'
          post 'custom_fields', to: 'agreement_templates#add_custom_field'
          post 'custom_fields/reorder', to: 'agreement_templates#reorder_custom_fields'
          post 'custom_fields/validate_formula', to: 'agreement_templates#validate_formula'
          patch 'custom_fields/:field_key', to: 'agreement_templates#update_custom_field'
          delete 'custom_fields/:field_key', to: 'agreement_templates#remove_custom_field'
        end
      end

      resources :agreements do
        collection do
          get :ai_scan_usage, to: 'agreements#ai_scan_usage_info'
        end
        member do
          post :send_agreement
          post :void
          post :remind
          post :remind_signer
          post :duplicate
          post :save_as_template
          get :audit_log
          get :download
          get :certificate
          post :prepare_signature
          post :calculate
          post :vision_scan
          get 'custom_fields', to: 'agreements#list_custom_fields'
          post 'custom_fields', to: 'agreements#add_custom_field'
          post 'custom_fields/validate_formula', to: 'agreements#validate_formula_field'
          patch 'custom_fields/:field_key', to: 'agreements#update_custom_field'
          delete 'custom_fields/:field_key', to: 'agreements#remove_custom_field'
        end

        collection do
          get :stats
          get :entity_context
          post :preview_calculate
        end

        # Nested signers
        post 'signers', to: 'agreements#add_signer'
        patch 'signers/:signer_id', to: 'agreements#update_signer'
        delete 'signers/:signer_id', to: 'agreements#remove_signer'

        # Nested attachments
        post 'attachments', to: 'agreements#add_attachment'
        delete 'attachments/:attachment_id', to: 'agreements#remove_attachment'
      end

      # Agreement Documents (upload, delete, merge & merge preview)
      post 'agreement_documents/upload', to: 'agreement_documents#upload'
      delete 'agreement_documents', to: 'agreement_documents#delete'
      post 'agreement_documents/merge', to: 'agreement_documents#merge'
      post 'agreement_documents/merge_preview', to: 'agreement_documents#merge_preview'

      # Agreement Merge Fields (definitions)
      get 'agreement_merge_fields', to: 'agreement_merge_fields#index'
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
    get 'settings/pipeline_stages', to: 'settings#pipeline_stages'
    patch 'settings/pipeline_stages', to: 'settings#update_pipeline_stages'
    
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

          # Custom field migration integrity check
          get :conversion_integrity_check
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
          member { post :trigger_step }
        end

        resources :templates, only: %i[index create update destroy] do
          collection { post :bulk }
          member { delete 'attachments/:attachment_id', to: 'templates#delete_attachment' }
        end
      end

      # ==================== INTAKE ====================
      namespace :intake do
        resources :forms do
          collection do
            post :bulk
            get :lead_fields
          end
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
          get :service_tickets # NEW: Get service tickets for this deal
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
        post :send_test_email, on: :collection
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

    # ==================== ADMIN NAMESPACE (Platform Admin Only) ====================
    namespace :admin do
      # Admin Buyers (Portal Users for Admin View)
      resources :buyers, only: [:index]
      
      # Admin Documents (Documents across all clients)
      resources :documents, only: [:index, :show, :create, :update, :destroy] do
        member do
          get :download
        end
      end
      
      resources :manufacturers do
        member do
          post :activate
          post :deactivate
        end
      end
    end

    # ==================== PLATFORM SETTINGS ====================
    namespace :platform do
      # ==================== SUBSCRIPTION PLANS ====================
      resources :subscription_plans, path: 'subscription-plans' do
        member do
          post :set_modules
          patch :set_module_config
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
        patch 'modules/config', to: 'tenant_subscriptions#update_module_config'
        
        member do
          get :check_domain_dns
          post :verify_domain
          post :generate_domain_token
          get :check_email_dns
          post :generate_email_dns_records
          post :verify_email_domain
          post :send_owner_invitation  # NEW: Send tenant owner invitation
          patch :update_owner_invitation  # NEW: Update owner invitation details
        end
        collection do
          get :check_subdomain_available
          get :check_domain_available
        end

        # Twilio SMS Provisioning (Platform Admin)
        post   'twilio/provision',   to: 'twilio_provisioning#provision'
        delete 'twilio/deprovision', to: 'twilio_provisioning#deprovision'
        get    'twilio/status',      to: 'twilio_provisioning#status'
      end

      # SMS Usage Dashboard (Platform Admin)
      get   'sms_usage',                        to: 'sms_usage#index'
      get   'sms_usage/:company_id',            to: 'sms_usage#show'
      patch 'sms_usage/:company_id/set_limit',  to: 'sms_usage#set_limit'

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
      
      # Portal Settings (Branding & Modules)
      get 'settings/branding', to: 'settings#branding'
      get 'settings/modules', to: 'settings#modules'
      
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
      
      # Portal Project Progress
      resources :projects, only: [:index, :show] do
        member do
          post :acknowledge_task  # POST body: { phase_id:, task_id: }
        end
      end

      # Portal Service Tickets
      resources :service_tickets, only: [:index, :show, :create], path: 'service-tickets'

      # Portal Agreements
      resources :agreements, only: [:index, :show] do
        member do
          get :download
        end
      end

      # Portal Home Configurator
      scope 'configurator' do
        get 'settings', to: 'configurator#settings'
        get 'floor-plans', to: 'configurator#floor_plans'
        get 'floor-plans/:id', to: 'configurator#floor_plan_detail'
        post 'submit', to: 'configurator#submit'
        get 'my-configurations', to: 'configurator#my_configurations'
      end
    end
  end

  # ==================== CONTRACTOR PORTAL ====================
  namespace :api do
    namespace :contractor do
      # Authentication
      post 'sessions/magic_link', to: 'sessions#magic_link'
      post 'sessions/verify', to: 'sessions#verify'

      # Dashboard
      get 'dashboard', to: 'dashboard#index'

      # Tasks
      resources :tasks, only: [:index, :show] do
        member do
          patch :update_status
          patch :toggle_checklist_item
        end
      end

      # Service Tickets
      resources :service_tickets, only: [:index, :show], path: 'service-tickets' do
        member do
          patch :update_status
        end
      end
    end
  end

  # ==================== PARTNER API (API Key Auth) ====================
  namespace :api do
    namespace :partner do
      namespace :v1 do
        # Health check
        get 'ping', to: 'ping#show'

        # Tier 1 - Core CRM Resources
        resources :contacts, only: [:index, :show, :create, :update, :destroy]
        resources :leads, only: [:index, :show, :create, :update, :destroy]
        resources :accounts, only: [:index, :show, :create, :update, :destroy]
        resources :deals, only: [:index, :show, :create, :update, :destroy]

        # Tier 2 - Operations & Inventory
        resources :vehicles, only: [:index, :show, :create, :update, :destroy]
        resources :invoices, only: [:index, :show, :create, :update, :destroy]
        resources :service_tickets, only: [:index, :show, :create, :update, :destroy], path: 'service-tickets'
        resources :quotes, only: [:index, :show, :create, :update, :destroy]

        # Tier 3 - Organization & Finance
        resources :locations, only: [:index, :show, :create, :update, :destroy]
        resources :users, only: [:index, :show]
        resources :payments, only: [:index, :show, :create, :update, :destroy]
        resources :loans, only: [:index, :show, :create, :update, :destroy]

        # Webhooks
        get 'webhook-events', to: 'webhook_events#index'
        resources :webhook_endpoints, only: [:index, :show, :create, :update, :destroy], path: 'webhook-endpoints' do
          resources :deliveries, only: [:index, :show], controller: 'webhook_deliveries'
        end
      end
    end
  end

end
