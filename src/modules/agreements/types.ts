// ============================================================
// Agreement System Types - Aligned with Backend Schema
// ============================================================

// --- Enums ---

export type AgreementStatus =
  | 'draft'
  | 'sent'
  | 'viewed'
  | 'partially_signed'
  | 'completed'
  | 'expired'
  | 'voided'
  | 'declined'

export type AgreementTemplateStatus = 'draft' | 'active' | 'archived'
export type AgreementTemplateType = 'upload' | 'editor'

export type SignerRole = 'signer' | 'preparer' | 'cc'
export type SignerStatus = 'pending' | 'sent' | 'viewed' | 'signed' | 'declined'
export type SigningOrder = 'parallel' | 'sequential' | 'counter_sign'
export type SignatureMethod = 'draw' | 'type' | 'upload'

export type AuditAction =
  | 'created'
  | 'updated'
  | 'sent'
  | 'viewed'
  | 'signed'
  | 'declined'
  | 'voided'
  | 'expired'
  | 'reminded'
  | 'downloaded'
  | 'attachment_added'
  | 'attachment_removed'
  | 'signer_added'
  | 'signer_removed'
  | 'completed'

export type ReminderStatus = 'pending' | 'sent' | 'failed' | 'cancelled'

// --- Core Interfaces ---

export interface AgreementCategory {
  id: number
  name: string
  description?: string
  is_system: boolean
  is_active: boolean
  position: number
  created_at: string
  updated_at: string
}

export interface AgreementTemplate {
  id: number
  name: string
  description?: string
  category_id?: number
  category?: AgreementCategory
  status: AgreementTemplateStatus
  template_type: AgreementTemplateType
  content?: string // Rich text HTML for editor type
  merge_fields?: string[] // Array of merge field keys used
  signing_order: SigningOrder
  default_expiry_days: number
  default_message?: string
  default_signers?: DefaultSigner[]
  is_system: boolean
  version: number
  document_url?: string // S3 URL for upload type
  created_at: string
  updated_at: string
}

export interface DefaultSigner {
  role: SignerRole
  order_index: number
  label?: string // e.g., "Buyer", "Seller", "Witness"
}

export interface Agreement {
  id: number
  agreement_number: string // AGR-2026-00001
  title: string
  description?: string
  status: AgreementStatus
  template_id?: number
  template?: AgreementTemplate
  category_id?: number
  category?: AgreementCategory
  content_type: AgreementTemplateType
  content?: string // Rich text HTML
  signing_order: SigningOrder
  message?: string // Message to signers
  expires_at?: string
  sent_at?: string
  completed_at?: string
  voided_at?: string
  voided_reason?: string
  declined_at?: string
  declined_reason?: string
  declined_by_signer_id?: number
  document_url?: string // Original document S3 URL
  sealed_document_url?: string // Sealed document S3 URL
  certificate_url?: string // Completion certificate S3 URL
  entity_type?: string // Polymorphic: 'Contact', 'Vehicle', 'Quote', etc.
  entity_id?: number
  entity_ids?: Record<string, number> // For merge fields: { contact_id: 1, vehicle_id: 2 }
  merge_field_values?: Record<string, string> // Resolved merge field values
  location_id?: number
  created_by_id?: number
  created_by_name?: string
  // Nested
  signers?: AgreementSigner[]
  attachments?: AgreementAttachment[]
  // Stats
  signing_progress?: { signed: number; total: number; percentage: number }
  created_at: string
  updated_at: string
}

export interface AgreementSigner {
  id: number
  agreement_id: number
  name: string
  email: string
  phone?: string
  role: SignerRole
  status: SignerStatus
  order_index: number
  access_token?: string // Only returned on creation
  signing_url?: string
  signature_url?: string // S3 URL to signature PNG
  initials_url?: string // S3 URL to initials PNG
  typed_signature?: string
  typed_initials?: string
  signature_font?: string
  signature_method?: SignatureMethod
  signed_at?: string
  viewed_at?: string
  declined_at?: string
  declined_reason?: string
  ip_address?: string
  user_agent?: string
  created_at: string
  updated_at: string
}

export interface AgreementAttachment {
  id: number
  agreement_id: number
  filename: string
  content_type: string
  byte_size: number
  url: string
  s3_key: string
  uploaded_by_name?: string
  created_at: string
}

export interface AgreementAuditLog {
  id: number
  agreement_id: number
  action: AuditAction
  actor_name?: string
  actor_email?: string
  actor_type: 'user' | 'signer' | 'system'
  ip_address?: string
  user_agent?: string
  metadata?: Record<string, any>
  created_at: string
}

export interface AgreementReminder {
  id: number
  agreement_id: number
  signer_id?: number
  signer_name?: string
  signer_email?: string
  status: ReminderStatus
  reminder_type: 'email' | 'sms'
  scheduled_at: string
  sent_at?: string
  created_at: string
}

// --- Merge Fields ---

export interface MergeFieldDefinition {
  key: string // e.g., "contact.first_name"
  label: string // e.g., "Contact First Name"
  category: string // e.g., "Contact", "Company", "Vehicle"
  sample_value?: string
}

export interface MergeFieldCategory {
  name: string
  entity_type: string // 'Contact', 'Company', etc.
  fields: MergeFieldDefinition[]
}

// --- API Request/Response Types ---

export interface CreateAgreementRequest {
  title: string
  description?: string
  template_id?: number
  category_id?: number
  content_type: AgreementTemplateType
  content?: string
  signing_order?: SigningOrder
  message?: string
  expires_at?: string
  entity_ids?: Record<string, number>
  signers?: CreateSignerRequest[]
}

export interface CreateSignerRequest {
  name: string
  email: string
  phone?: string
  role: SignerRole
  order_index: number
}

export interface SendAgreementRequest {
  message?: string
}

export interface SignAgreementRequest {
  signature_data?: string // Base64 PNG (will be uploaded to S3 by backend)
  initials_data?: string // Base64 PNG
  typed_signature?: string
  typed_initials?: string
  signature_font?: string
  signature_method: SignatureMethod
}

export interface AgreementFilters {
  status?: AgreementStatus
  category_id?: number
  search?: string
  page?: number
  per_page?: number
  sort_by?: string
  sort_order?: 'asc' | 'desc'
}

export interface AgreementListResponse {
  items: Agreement[]
  meta: {
    total: number
    page: number
    per_page: number
    total_pages: number
    stats: {
      total: number
      draft: number
      sent: number
      viewed: number
      partially_signed: number
      completed: number
      expired: number
      voided: number
      declined: number
    }
  }
}

export interface TemplateFilters {
  status?: AgreementTemplateStatus
  category_id?: number
  template_type?: AgreementTemplateType
  search?: string
  page?: number
  per_page?: number
}

export interface TemplateListResponse {
  items: AgreementTemplate[]
  meta: {
    total: number
    page: number
    per_page: number
    total_pages: number
    stats: {
      total: number
      active: number
      draft: number
      archived: number
    }
  }
}
