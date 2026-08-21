class GeneralizeIngestionSchema < ActiveRecord::Migration[8.1]
  def change
    drop_table :payment_ingestions, if_exists: true
    drop_table :payment_documents, if_exists: true

    create_table :source_documents do |t|
      t.references :user, null: false, foreign_key: true
      t.string :document_type, null: false, default: "unknown"
      t.binary :attachment_file
      t.string :attachment_filename
      t.string :attachment_content_type
      t.string :status, null: false, default: "processing"
      t.text :error_message

      t.timestamps
    end

    create_table :imported_transactions do |t|
      t.references :user, null: false, foreign_key: true
      t.references :source_document, null: false, foreign_key: true
      t.string :source, null: false
      t.string :transaction_kind, null: false, default: "unknown"
      t.bigint :amount_cents
      t.date :occurred_on
      t.string :payment_method
      t.string :external_reference
      t.string :payer_name
      t.string :payer_username
      t.text :raw_text
      t.references :matched_party, foreign_key: { to_table: :parties }, null: true
      t.references :matched_tenancy, foreign_key: { to_table: :tenancies }, null: true
      t.string :status, null: false, default: "pending"
      t.text :error_message
      t.string :confirmed_source_type
      t.bigint :confirmed_source_id

      t.timestamps
    end

    add_check_constraint :imported_transactions,
                         "amount_cents IS NULL OR amount_cents > 0",
                         name: "imported_transactions_amount_cents_check"

    add_check_constraint :imported_transactions,
                         "transaction_kind IN ('unknown', 'tenant_receipt', 'security_deposit')",
                         name: "imported_transactions_kind_check"

    add_check_constraint :imported_transactions,
                         "status IN ('pending', 'matched', 'unmatched', 'ambiguous', 'confirmed', 'failed')",
                         name: "imported_transactions_status_check"

    add_check_constraint :imported_transactions,
                         "(confirmed_source_type IS NULL AND confirmed_source_id IS NULL) OR (confirmed_source_type IS NOT NULL AND confirmed_source_id IS NOT NULL)",
                         name: "imported_transactions_confirmed_source_check"

    add_index :imported_transactions,
              %i[user_id source payment_method external_reference],
              unique: true,
              where: "payment_method IS NOT NULL AND external_reference IS NOT NULL",
              name: "idx_imported_txns_user_src_method_ext_ref"

    add_index :imported_transactions,
              %i[confirmed_source_type confirmed_source_id],
              unique: true,
              where: "confirmed_source_id IS NOT NULL",
              name: "idx_imported_txns_confirmed_source"
  end
end
