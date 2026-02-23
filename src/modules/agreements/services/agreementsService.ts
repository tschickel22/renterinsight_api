import apiClient from '@/services/apiClient'
import type {
  Agreement,
  AgreementFilters,
  AgreementListResponse,
  AgreementCategory,
  AgreementTemplate,
  TemplateFilters,
  TemplateListResponse,
  AgreementAuditLog,
  AgreementReminder,
  MergeFieldCategory,
  CreateAgreementRequest,
  SendAgreementRequest,
  CreateSignerRequest,
} from '../types'

const BASE = '/api/v1'

// ==================== Categories ====================

export async function getCategories(): Promise<AgreementCategory[]> {
  const response = await apiClient.get(`${BASE}/agreement_categories`)
  return response.data?.items || response.data || []
}

export async function createCategory(data: Partial<AgreementCategory>): Promise<AgreementCategory> {
  const response = await apiClient.post(`${BASE}/agreement_categories`, { agreement_category: data })
  return response.data
}

export async function updateCategory(id: number, data: Partial<AgreementCategory>): Promise<AgreementCategory> {
  const response = await apiClient.patch(`${BASE}/agreement_categories/${id}`, { agreement_category: data })
  return response.data
}

export async function deleteCategory(id: number): Promise<void> {
  await apiClient.delete(`${BASE}/agreement_categories/${id}`)
}

// ==================== Templates ====================

export async function getTemplates(filters?: TemplateFilters): Promise<TemplateListResponse> {
  const params = new URLSearchParams()
  if (filters?.status) params.append('status', filters.status)
  if (filters?.category_id) params.append('category_id', String(filters.category_id))
  if (filters?.template_type) params.append('template_type', filters.template_type)
  if (filters?.search) params.append('search', filters.search)
  if (filters?.page) params.append('page', String(filters.page))
  if (filters?.per_page) params.append('per_page', String(filters.per_page))

  const response = await apiClient.get(`${BASE}/agreement_templates?${params}`)
  return response.data
}

export async function getTemplate(id: number): Promise<AgreementTemplate> {
  const response = await apiClient.get(`${BASE}/agreement_templates/${id}`)
  return response.data
}

export async function createTemplate(data: Partial<AgreementTemplate>): Promise<AgreementTemplate> {
  const response = await apiClient.post(`${BASE}/agreement_templates`, { agreement_template: data })
  return response.data
}

export async function updateTemplate(id: number, data: Partial<AgreementTemplate>): Promise<AgreementTemplate> {
  const response = await apiClient.patch(`${BASE}/agreement_templates/${id}`, { agreement_template: data })
  return response.data
}

export async function deleteTemplate(id: number): Promise<void> {
  await apiClient.delete(`${BASE}/agreement_templates/${id}`)
}

export async function duplicateTemplate(id: number): Promise<AgreementTemplate> {
  const response = await apiClient.post(`${BASE}/agreement_templates/${id}/duplicate`)
  return response.data
}

export async function publishTemplate(id: number): Promise<AgreementTemplate> {
  const response = await apiClient.post(`${BASE}/agreement_templates/${id}/publish`)
  return response.data
}

export async function archiveTemplate(id: number): Promise<AgreementTemplate> {
  const response = await apiClient.post(`${BASE}/agreement_templates/${id}/archive`)
  return response.data
}

export async function uploadTemplateDocument(id: number, file: File): Promise<{ document_url: string }> {
  const formData = new FormData()
  formData.append('document', file)
  const response = await apiClient.post(`${BASE}/agreement_templates/${id}/upload`, formData, {
    headers: { 'Content-Type': 'multipart/form-data' }
  })
  return response.data
}

// ==================== Agreements ====================

export async function getAgreements(filters?: AgreementFilters): Promise<AgreementListResponse> {
  const params = new URLSearchParams()
  if (filters?.status) params.append('status', filters.status)
  if (filters?.category_id) params.append('category_id', String(filters.category_id))
  if (filters?.search) params.append('search', filters.search)
  if (filters?.page) params.append('page', String(filters.page))
  if (filters?.per_page) params.append('per_page', String(filters.per_page))
  if (filters?.sort_by) params.append('sort_by', filters.sort_by)
  if (filters?.sort_order) params.append('sort_order', filters.sort_order)

  const response = await apiClient.get(`${BASE}/agreements?${params}`)
  return response.data
}

export async function getAgreement(id: number): Promise<Agreement> {
  const response = await apiClient.get(`${BASE}/agreements/${id}`)
  return response.data
}

export async function createAgreement(data: CreateAgreementRequest): Promise<Agreement> {
  const response = await apiClient.post(`${BASE}/agreements`, { agreement: data })
  return response.data
}

export async function updateAgreement(id: number, data: Partial<Agreement>): Promise<Agreement> {
  const response = await apiClient.patch(`${BASE}/agreements/${id}`, { agreement: data })
  return response.data
}

export async function deleteAgreement(id: number): Promise<void> {
  await apiClient.delete(`${BASE}/agreements/${id}`)
}

export async function duplicateAgreement(id: number): Promise<Agreement> {
  const response = await apiClient.post(`${BASE}/agreements/${id}/duplicate`)
  return response.data
}

export async function sendAgreement(id: number, data?: SendAgreementRequest): Promise<Agreement> {
  const response = await apiClient.post(`${BASE}/agreements/${id}/send_agreement`, data || {})
  return response.data
}

export async function voidAgreement(id: number, reason: string): Promise<Agreement> {
  const response = await apiClient.post(`${BASE}/agreements/${id}/void`, { reason })
  return response.data
}

export async function remindAllSigners(id: number): Promise<void> {
  await apiClient.post(`${BASE}/agreements/${id}/remind`)
}

export async function remindSigner(agreementId: number, signerId: number): Promise<void> {
  await apiClient.post(`${BASE}/agreements/${agreementId}/remind_signer`, { signer_id: signerId })
}

export async function getAuditLog(id: number): Promise<AgreementAuditLog[]> {
  const response = await apiClient.get(`${BASE}/agreements/${id}/audit_log`)
  return response.data
}

export async function getAgreementStats(): Promise<Record<string, number>> {
  const response = await apiClient.get(`${BASE}/agreements/stats`)
  return response.data
}

// ==================== Signers ====================

export async function addSigner(agreementId: number, data: CreateSignerRequest): Promise<Agreement> {
  const response = await apiClient.post(`${BASE}/agreements/${agreementId}/signers`, { signer: data })
  return response.data
}

export async function removeSigner(agreementId: number, signerId: number): Promise<Agreement> {
  const response = await apiClient.delete(`${BASE}/agreements/${agreementId}/signers/${signerId}`)
  return response.data
}

export async function updateSignerOrder(agreementId: number, signerIds: number[]): Promise<Agreement> {
  const response = await apiClient.patch(`${BASE}/agreements/${agreementId}/signers/reorder`, { signer_ids: signerIds })
  return response.data
}

// ==================== Attachments ====================

export async function addAttachment(agreementId: number, file: File): Promise<Agreement> {
  const formData = new FormData()
  formData.append('file', file)
  const response = await apiClient.post(`${BASE}/agreements/${agreementId}/attachments`, formData, {
    headers: { 'Content-Type': 'multipart/form-data' }
  })
  return response.data
}

export async function removeAttachment(agreementId: number, attachmentId: number): Promise<Agreement> {
  const response = await apiClient.delete(`${BASE}/agreements/${agreementId}/attachments/${attachmentId}`)
  return response.data
}

// ==================== Documents ====================

export async function uploadDocument(agreementId: number, file: File): Promise<{ document_url: string }> {
  const formData = new FormData()
  formData.append('document', file)
  const response = await apiClient.post(`${BASE}/agreement_documents/${agreementId}/upload`, formData, {
    headers: { 'Content-Type': 'multipart/form-data' }
  })
  return response.data
}

export async function previewMergeFields(agreementId: number): Promise<Record<string, string>> {
  const response = await apiClient.get(`${BASE}/agreement_documents/${agreementId}/merge_preview`)
  return response.data
}

// ==================== Merge Fields ====================

export async function getMergeFieldDefinitions(): Promise<MergeFieldCategory[]> {
  const response = await apiClient.get(`${BASE}/agreement_merge_fields`)
  return response.data
}

// ==================== Public Signing (no auth) ====================

const API_BASE = import.meta.env.VITE_RAILS_API_URL || 'https://localhost:3001'

export async function getPublicAgreement(token: string): Promise<{
  agreement: Agreement
  signer: AgreementSigner
}> {
  const response = await fetch(`${API_BASE}/sign/${token}`, {
    headers: { 'Content-Type': 'application/json' }
  })
  if (!response.ok) throw new Error('Agreement not found or expired')
  return response.json()
}

export async function recordPublicView(token: string): Promise<void> {
  await fetch(`${API_BASE}/sign/${token}/view`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' }
  })
}

export async function submitPublicSignature(token: string, data: {
  signature_data?: string
  initials_data?: string
  typed_signature?: string
  typed_initials?: string
  signature_font?: string
  signature_method: 'draw' | 'type' | 'upload'
}): Promise<{ success: boolean; message: string }> {
  const response = await fetch(`${API_BASE}/sign/${token}/sign`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(data)
  })
  if (!response.ok) {
    const error = await response.json()
    throw new Error(error.error || 'Failed to submit signature')
  }
  return response.json()
}

export async function submitPublicDecline(token: string, reason?: string): Promise<void> {
  const response = await fetch(`${API_BASE}/sign/${token}/decline`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ reason })
  })
  if (!response.ok) throw new Error('Failed to decline agreement')
}

export async function downloadPublicDocument(token: string): Promise<Blob> {
  const response = await fetch(`${API_BASE}/sign/${token}/download`)
  if (!response.ok) throw new Error('Failed to download document')
  return response.blob()
}

// ==================== Portal Agreements ====================

export async function getPortalAgreements(filters?: { status?: string; page?: number; per_page?: number }): Promise<{
  items: Agreement[]
  meta: { total: number; page: number; per_page: number; total_pages: number }
}> {
  const params = new URLSearchParams()
  if (filters?.status) params.append('status', filters.status)
  if (filters?.page) params.append('page', String(filters.page))
  if (filters?.per_page) params.append('per_page', String(filters.per_page))

  const response = await apiClient.get(`/api/portal/agreements?${params}`)
  return response.data
}

export async function getPortalAgreement(id: number): Promise<Agreement> {
  const response = await apiClient.get(`/api/portal/agreements/${id}`)
  return response.data
}

export async function downloadPortalDocument(id: number): Promise<Blob> {
  const response = await apiClient.get(`/api/portal/agreements/${id}/download`, {
    responseType: 'blob'
  })
  return response.data
}
