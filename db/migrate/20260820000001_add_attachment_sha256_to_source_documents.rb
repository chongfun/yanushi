require "digest"

class AddAttachmentSha256ToSourceDocuments < ActiveRecord::Migration[8.1]
  def up
    add_column :source_documents, :attachment_sha256, :string

    SourceDocument.reset_column_information
    SourceDocument.find_each do |doc|
      if doc.attachment_file.present?
        doc.update_columns(attachment_sha256: Digest::SHA256.hexdigest(doc.attachment_file))
      end
    end

    change_column_null :source_documents, :attachment_sha256, false
    add_index :source_documents, %i[user_id attachment_sha256], unique: true, name: "idx_source_documents_user_id_sha256"
  end

  def down
    remove_index :source_documents, name: "idx_source_documents_user_id_sha256"
    remove_column :source_documents, :attachment_sha256
  end
end
