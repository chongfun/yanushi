class AddPaymentDocumentToPaymentReceiptIngestions < ActiveRecord::Migration[8.1]
  def up
    add_reference :payment_receipt_ingestions, :payment_document, null: true, foreign_key: true

    # Temporary classes to migrate data
    local_ingestion_class = Class.new(ActiveRecord::Base) do
      self.table_name = 'payment_receipt_ingestions'
    end
    local_document_class = Class.new(ActiveRecord::Base) do
      self.table_name = 'payment_documents'
    end

    local_ingestion_class.where.not(attachment_file: nil).find_each do |ingestion|
      doc = local_document_class.create!(
        user_id: ingestion.user_id,
        attachment_file: ingestion.attachment_file,
        attachment_filename: ingestion.attachment_filename,
        attachment_content_type: ingestion.attachment_content_type,
        created_at: ingestion.created_at,
        updated_at: ingestion.updated_at
      )
      ingestion.update_column(:payment_document_id, doc.id)
    end

    remove_column :payment_receipt_ingestions, :attachment_file, :binary
    remove_column :payment_receipt_ingestions, :attachment_filename, :string
    remove_column :payment_receipt_ingestions, :attachment_content_type, :string
  end

  def down
    add_column :payment_receipt_ingestions, :attachment_file, :binary
    add_column :payment_receipt_ingestions, :attachment_filename, :string
    add_column :payment_receipt_ingestions, :attachment_content_type, :string

    local_ingestion_class = Class.new(ActiveRecord::Base) do
      self.table_name = 'payment_receipt_ingestions'
    end
    local_document_class = Class.new(ActiveRecord::Base) do
      self.table_name = 'payment_documents'
    end

    local_ingestion_class.where.not(payment_document_id: nil).find_each do |ingestion|
      doc = local_document_class.find_by(id: ingestion.payment_document_id)
      if doc
        ingestion.update_columns(
          attachment_file: doc.attachment_file,
          attachment_filename: doc.attachment_filename,
          attachment_content_type: doc.attachment_content_type
        )
      end
    end

    remove_reference :payment_receipt_ingestions, :payment_document
  end
end
