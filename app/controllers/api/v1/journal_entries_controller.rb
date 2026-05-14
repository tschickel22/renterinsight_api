# frozen_string_literal: true

class Api::V1::JournalEntriesController < ApplicationController
  include AccountingLocationScoping

  before_action :set_company_scope
  before_action :set_journal_entry, only: [:show, :update, :void, :destroy]

  def index
    return unless authorize_action!('journal_entries', 'read')

    entries = @company.journal_entries.includes(:journal_entry_lines, :posted_by)

    # Filter by accounting location bar (separate from the global location selector)
    je_ids = je_ids_for_accounting_location
    entries = entries.where(id: je_ids) if je_ids

    stats = {
      total: entries.count,
      posted: entries.posted.count,
      voided: entries.voided.count
    }

    entries = entries.where(source_type: params[:source_type]) if params[:source_type].present?
    entries = entries.where(is_void: params[:is_void]) if params[:is_void].present?
    if params[:start_date].present? && params[:end_date].present?
      entries = entries.for_date_range(params[:start_date], params[:end_date])
    end

    if params[:search].present?
      search_term = "%#{params[:search]}%"
      entries = entries.where(
        "entry_number ILIKE ? OR memo ILIKE ?",
        search_term, search_term
      )
    end

    sort_by = params[:sort_by] || 'entry_date'
    sort_order = params[:sort_order]&.downcase == 'asc' ? :asc : :desc
    entries = entries.order(sort_by => sort_order)

    filtered_count = entries.count

    page = (params[:page] || 1).to_i
    per_page = [(params[:per_page] || 50).to_i, 200].min
    entries = entries.offset((page - 1) * per_page).limit(per_page)

    render json: {
      items: entries.as_json(
        include: {
          journal_entry_lines: {
            include: { chart_of_account: { only: [:id, :account_number, :name, :account_type] } }
          },
          posted_by: { only: [:id, :email, :first_name, :last_name] }
        }
      ),
      meta: {
        total: filtered_count,
        page: page,
        per_page: per_page,
        total_pages: (filtered_count.to_f / per_page).ceil,
        stats: stats
      }
    }
  end

  def show
    return unless authorize_action!('journal_entries', 'read')

    render json: @journal_entry.as_json(
      include: {
        journal_entry_lines: {
          include: {
            chart_of_account: { only: [:id, :account_number, :name, :account_type] },
            location: { only: [:id, :name] },
            contact: { only: [:id, :first_name, :last_name, :company_name] },
            deal: { only: [:id, :title] },
            vehicle: { only: [:id, :year, :make, :model, :stock_number] }
          }
        },
        posted_by: { only: [:id, :email, :first_name, :last_name] },
        voided_by: { only: [:id, :email, :first_name, :last_name] },
        reversed_by: { only: [:id, :entry_number] }
      }
    )
  end

  def create
    return unless authorize_action!('journal_entries', 'create')

    entry = @company.journal_entries.build(journal_entry_params)
    entry.posted_by = current_user
    entry.source_type = 'manual'

    if entry.save
      render json: entry.as_json(
        include: { journal_entry_lines: { include: { chart_of_account: { only: [:id, :account_number, :name] } } } }
      ), status: :created
    else
      render json: { errors: entry.errors }, status: :unprocessable_entity
    end
  end

  def update
    return unless authorize_action!('journal_entries', 'update')

    if @journal_entry.locked?
      return render json: { error: 'Cannot edit a locked journal entry' }, status: :unprocessable_entity
    end

    if @journal_entry.is_void?
      return render json: { error: 'Cannot edit a voided journal entry' }, status: :unprocessable_entity
    end

    if @journal_entry.update(journal_entry_params)
      render json: @journal_entry.as_json(
        include: { journal_entry_lines: { include: { chart_of_account: { only: [:id, :account_number, :name] } } } }
      )
    else
      render json: { errors: @journal_entry.errors }, status: :unprocessable_entity
    end
  end

  # POST /api/v1/journal_entries/:id/void
  def void
    return unless authorize_action!('journal_entries', 'update')

    if @journal_entry.is_void?
      return render json: { error: 'Entry is already voided' }, status: :unprocessable_entity
    end

    @journal_entry.void!(current_user)
    render json: { message: 'Journal entry voided', journal_entry: @journal_entry }
  rescue => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # DELETE /api/v1/journal_entries/:id
  def destroy
    return unless authorize_action!('journal_entries', 'delete')

    # If voided, also delete the reversing entry
    if @journal_entry.is_void? && @journal_entry.reversed_by_id.present?
      reversing_id = @journal_entry.reversed_by_id
      # Clear FK reference BEFORE deleting the reversing entry
      @journal_entry.update_columns(reversed_by_id: nil)
      reversing = @company.journal_entries.find_by(id: reversing_id)
      reversing&.destroy!
    end

    # If this IS a reversing entry (locked), clear the original's reference first
    if @journal_entry.locked?
      original = @company.journal_entries.find_by(reversed_by_id: @journal_entry.id)
      if original
        original.update_columns(is_void: false, voided_at: nil, voided_by_id: nil, reversed_by_id: nil)
      end
    end

    @journal_entry.destroy!
    head :no_content
  rescue => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # POST /api/v1/journal_entries/:id/upload_attachment
  def upload_attachment
    return unless authorize_action!('accounting', 'update')

    je = @company.journal_entries.find(params[:id])
    file = params[:file]
    return render json: { error: 'No file provided' }, status: :bad_request unless file

    s3 = S3UploadService.new
    result = s3.upload(file, folder: "journal_entries/#{@company.id}/#{je.id}")

    attachment = {
      'url' => result[:url],
      's3_key' => result[:key],
      'filename' => file.original_filename,
      'size' => result[:size],
      'content_type' => result[:content_type],
      'uploaded_at' => Time.current.iso8601,
      'uploaded_by_id' => current_user&.id
    }

    je.update!(attachments: (je.attachments || []) + [attachment])
    render json: attachment
  rescue => e
    render json: { error: "Upload failed: #{e.message}" }, status: :unprocessable_entity
  end

  # DELETE /api/v1/journal_entries/:id/delete_attachment
  def delete_attachment
    return unless authorize_action!('accounting', 'update')

    je = @company.journal_entries.find(params[:id])
    s3_key = params[:s3_key]
    return render json: { error: 'No s3_key provided' }, status: :bad_request unless s3_key.present?

    begin
      s3 = S3UploadService.new
      s3.delete(s3_key)
    rescue => e
      Rails.logger.warn("[JE] S3 delete failed for #{s3_key}: #{e.message}")
    end

    je.update!(attachments: (je.attachments || []).reject { |a| a['s3_key'] == s3_key })
    render json: { message: 'Attachment deleted' }
  end

  private

  def set_journal_entry
    @journal_entry = @company.journal_entries.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Journal entry not found' }, status: :not_found
  end

  def journal_entry_params
    params.require(:journal_entry).permit(
      :entry_date, :memo, :is_adjusting,
      journal_entry_lines_attributes: [
        :id, :chart_of_account_id, :debit_amount, :credit_amount,
        :memo, :location_id, :department, :contact_id, :deal_id,
        :vehicle_id, :position, :_destroy
      ]
    )
  end
end
